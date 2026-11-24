import Foundation
import Combine
import Darwin

@MainActor
final class ControlStore: ObservableObject {
    @Published private(set) var settings = ControlSettings()
    @Published private(set) var snapshot: BackendSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var message = "Chưa kết nối backend."
    @Published private(set) var persistenceError: String?
    @Published private(set) var confirmedRevision: String?
    @Published private(set) var revision = UUID().uuidString
    @Published private(set) var backendTrace: BackendExchangeTrace?
    @Published private(set) var runtimeOperationMessage: String?
    private var runtimeOperationTrace: BackendExchangeTrace?
    @Published var selectedGroup: FeatureGroup = .esp
    private let backend: any BackendClient
    private let profileURL: URL
    private var profileLocked = false
    private var pendingRevision: String?
    private var pendingSession: String?

    init(directory: URL? = nil, backend: any BackendClient = NativeBackend()) {
        self.backend = backend
        let folder = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        profileURL = folder.appendingPathComponent("HeroControl.profile.json")
        transaction {}
        do {
            if FileManager.default.fileExists(atPath: profileURL.path) {
                let (saved, migrated) = try ProfileCodec.decode(Data(contentsOf: profileURL))
                guard saved.schemaVersion == 1 else { throw BackendError.unavailable("Phiên bản cấu hình không hỗ trợ.") }
                settings = saved.settings
                settings.normalize()
                if let savedRevision = saved.revision { revision = savedRevision }
                if migrated { persist() }
            }
        } catch { persistenceError = "Không đọc được cấu hình: \(error.localizedDescription)" }
    }

    var connected: Bool { snapshot?.connected == true }
    var canApply: Bool {
        connected && snapshot?.gameRunning == true && !(snapshot?.sessionID?.isEmpty ?? true) && !busy && persistenceError == nil && unsupportedKeys.isEmpty
    }
    var isApplied: Bool {
        connected && snapshot?.gameRunning == true && persistenceError == nil && confirmedRevision == revision && snapshot?.appliedRevision == revision
    }
    var unsupportedKeys: [String] {
        guard let snapshot, snapshot.connected else { return [] }
        let supported = Set(snapshot.supportedKeys)
        return settings.preferenceValues.keys.filter { !supported.contains($0) }.sorted()
    }
    func supports(_ key: String) -> Bool { snapshot?.supportedKeys.contains(key) == true }
    func setFlag(_ key: String, _ value: Bool) {
        guard Feature.all.contains(where: { $0.key == key }) else { return }
        edit { settings.flags[key] = value }
    }
    func setCamera(_ value: Double) { edit { settings.cameraScale = value } }
    func setCameraEnabled(_ value: Bool) { edit { settings.cameraEnabled = value } }
    func setCaptureProtected(_ value: Bool) { edit { settings.espCaptureProtected = value } }
    func setMinimap(_ key: String, _ value: Double) {
        edit {
            switch key {
            case "x": settings.minimapX = value
            case "y": settings.minimapY = value
            case "size": settings.minimapSize = value
            case "extent": settings.minimapWorldExtent = value
            default: break
            }
        }
    }
    func setMinimapRotated(_ value: Bool) { edit { settings.minimapRotated = value } }
    func setEspReadHz(_ value: Int) { edit { settings.espReadHz = value } }
    func prepareCombinedCheck() {
        edit {
            for feature in Feature.all where feature.group == .esp {
                settings.flags[feature.key] = feature.key != "DoroCheat.Reference.R1.Unseen"
            }
            settings.flags["reports.enabled"] = true
        }
    }
    func setSkin(hero: UInt32, skin: Int?) {
        edit {
            if let skin, let entry = snapshot?.heroes.first(where: { $0.id == hero }),
               entry.skins.contains(where: { $0.id == skin }) {
                settings.selectedSkins[String(hero)] = skin
            } else if skin == nil { settings.selectedSkins.removeValue(forKey: String(hero)) }
        }
    }
    func reset() {
        transaction {
            let runtime = settings.gameRuntimeEnabled
            settings = ControlSettings(); settings.gameRuntimeEnabled = runtime; changed()
        }
    }
    private func transaction(_ body: () -> Void) {
        if profileLocked { body(); return }
        let fd = open(profileURL.path + ".edit-lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { persistenceError = "Không mở được khóa cấu hình (errno \(errno))."; return }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_uid == geteuid(),
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            persistenceError = "Cấu hình đang được sửa hoặc khóa không hợp lệ; thử lại."; return
        }
        defer { flock(fd, LOCK_UN) }
        profileLocked = true
        defer { profileLocked = false }
        body()
    }
    private func edit(_ mutate: () -> Void) {
        transaction {
            reloadProfileIfChanged()
            guard persistenceError == nil else { return }
            mutate(); changed()
        }
    }
    // Import edits made by the independent HUD without treating them as a game
    // acknowledgement. Revisions change even while the backend is disconnected.
    func reloadProfileIfChanged() {
        transaction { reloadProfileUnlocked() }
    }
    private func reloadProfileUnlocked() {
        guard FileManager.default.fileExists(atPath: profileURL.path) else { persistenceError = nil; return }
        do {
            let data = try Data(contentsOf: profileURL)
            guard data.count <= 131072 else { throw BackendError.unavailable("Cấu hình quá lớn.") }
            let (saved, migrated) = try ProfileCodec.decode(data)
            guard saved.schemaVersion == 1 else { throw BackendError.unavailable("Phiên bản cấu hình không hỗ trợ.") }
            var imported = saved.settings; imported.normalize()
            if imported != settings || (saved.revision != nil && saved.revision != revision) {
                settings = imported; revision = saved.revision ?? UUID().uuidString; confirmedRevision = nil
                pendingRevision = nil; pendingSession = nil
            }
            persistenceError = nil
            if migrated { persist() }
        } catch { persistenceError = "Không đọc được cấu hình từ menu nổi: \(error.localizedDescription)" }
    }
    func prepareOverlayProfile() -> URL? {
        if !FileManager.default.fileExists(atPath: profileURL.path) { persist() }
        return persistenceError == nil ? profileURL : nil
    }
    private func changed() {
        settings.normalize()
        revision = UUID().uuidString
        confirmedRevision = nil
        pendingRevision = nil; pendingSession = nil
        persist()
    }
    private func persist() {
        transaction { persistUnlocked() }
    }
    private func persistUnlocked() {
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(SavedProfile(schemaVersion: 1, settings: settings, revision: revision))
            try data.write(to: profileURL, options: .atomic)
            persistenceError = nil
        } catch { persistenceError = "Chưa lưu được cấu hình: \(error.localizedDescription)" }
    }
    func refresh() async {
        await requestStatus(action: "status")
    }
    func diagnose() async {
        await requestStatus(action: "diagnose")
    }
    func inspectGame() async {
        await requestStatus(action: "inspectGame")
    }
    func installRuntime() async {
        guard !busy else { return }
        var previous: Bool? = nil
        edit { previous = settings.gameRuntimeEnabled; settings.gameRuntimeEnabled = true }
        guard persistenceError == nil else { return }
        await requestStatus(action: "installRuntime")
        if snapshot?.runtimeDiagnostics?.code != "runtime_installed_restart_required" {
            edit { settings.gameRuntimeEnabled = previous }
        }
    }
    func removeRuntime() async {
        guard !busy else { return }
        await requestStatus(action: "removeRuntime")
        if snapshot?.runtimeDiagnostics?.code == "runtime_removed_restart_required" {
            // Keep external workers off until the user has restarted the game;
            // the old in-memory hooks cannot be removed by deleting a dylib.
            message = "Đã gỡ bộ nạp. Đóng hoàn toàn và mở lại game để gỡ các hook trong bộ nhớ."
        }
    }
    private func requestStatus(action: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let reply = try await backend.send(action: action, revision: revision, settings: settings)
            backendTrace = await backend.exchangeTrace()
            guard reply.ok, reply.protocolVersion == 1, reply.snapshot?.protocolVersion == 1 else {
                throw BackendError.unavailable(reply.message)
            }
            accept(reply.snapshot)
            message = reply.message
            if action == "installRuntime" || action == "removeRuntime" {
                runtimeOperationMessage = reply.message; runtimeOperationTrace = backendTrace
            }
        } catch {
            backendTrace = await backend.exchangeTrace()
            if let backendError = error as? BackendError, case .rejected(_, let data) = backendError,
               let reply = try? BackendReplyDecoder.decode(data), reply.protocolVersion == 1,
               reply.snapshot?.protocolVersion == 1 {
                accept(reply.snapshot)
                message = error.localizedDescription
            } else { disconnected(error) }
            if action == "installRuntime" || action == "removeRuntime" {
                runtimeOperationMessage = error.localizedDescription; runtimeOperationTrace = backendTrace
            }
        }
    }
    func apply() async {
        guard canApply else { return }
        let sentRevision = revision, sentSettings = settings, sentSession = snapshot?.sessionID
        pendingRevision = sentRevision; pendingSession = sentSession
        busy = true
        defer { busy = false }
        do {
            let reply = try await backend.send(action: "apply", revision: sentRevision, settings: sentSettings)
            backendTrace = await backend.exchangeTrace()
            accept(reply.snapshot)
            guard reply.ok, reply.protocolVersion == 1, let result = reply.snapshot, result.protocolVersion == 1,
                  result.connected, result.gameRunning, result.sessionID == sentSession,
                  !(result.sessionID?.isEmpty ?? true), result.appliedRevision == sentRevision else {
                confirmedRevision = nil
                message = reply.message + " Chưa xác nhận áp dụng; vào game rồi quay lại kiểm tra."
                return
            }
            confirmedRevision = sentRevision
            pendingRevision = nil; pendingSession = nil
            message = revision == sentRevision ? "Runtime đã đọc lại cấu hình. Cần kiểm chứng hiệu ứng trong game." : "Đã đồng bộ bản trước; còn thay đổi chưa đồng bộ."
        } catch {
            pendingRevision = nil; pendingSession = nil
            backendTrace = await backend.exchangeTrace()
            disconnected(error)
        }
    }
    private func accept(_ value: BackendSnapshot?) {
        if value?.sessionID != snapshot?.sessionID || value?.connected != true || value?.gameRunning != true {
            confirmedRevision = nil
        }
        if let pendingRevision, let pendingSession,
           value?.connected == true, value?.gameRunning == true {
            if value?.sessionID == pendingSession, value?.appliedRevision == pendingRevision, revision == pendingRevision {
                confirmedRevision = pendingRevision
                self.pendingRevision = nil; self.pendingSession = nil
            } else if value?.sessionID != pendingSession {
                self.pendingRevision = nil; self.pendingSession = nil
            }
        }
        snapshot = value
    }
    private func disconnected(_ error: Error) {
        snapshot = nil
        confirmedRevision = nil
        message = error.localizedDescription
    }
    func exportDiagnostics(overlayState: OverlayState? = nil) throws -> URL {
        struct Diagnostics: Encodable {
            let schemaVersion: Int
            let settings: ControlSettings
            let revision: String
            let confirmedRevision: String?
            let snapshot: BackendSnapshot?
            let message: String
            let appVersion: String
            let appBuild: String
            let backendExchange: BackendExchangeTrace?
            let runtimeOperationMessage: String?
            let runtimeOperationExchange: BackendExchangeTrace?
            let overlay: OverlayState?
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let diagnostics = Diagnostics(schemaVersion: 1, settings: settings, revision: revision,
                                      confirmedRevision: confirmedRevision, snapshot: snapshot, message: message,
                                      appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                                      appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                                      backendExchange: backendTrace, runtimeOperationMessage: runtimeOperationMessage,
                                      runtimeOperationExchange: runtimeOperationTrace, overlay: overlayState)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HeroControl-diagnostics.json")
        try encoder.encode(diagnostics).write(to: url, options: .atomic)
        return url
    }
}
