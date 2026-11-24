import Foundation
import Combine

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
    @Published var selectedGroup: FeatureGroup = .esp
    private let backend: any BackendClient
    private let profileURL: URL

    init(directory: URL? = nil, backend: any BackendClient = NativeBackend()) {
        self.backend = backend
        let folder = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        profileURL = folder.appendingPathComponent("HeroControl.profile.json")
        do {
            if FileManager.default.fileExists(atPath: profileURL.path) {
                let (saved, migrated) = try ProfileCodec.decode(Data(contentsOf: profileURL))
                guard saved.schemaVersion == 1 else { throw BackendError.unavailable("Phiên bản cấu hình không hỗ trợ.") }
                settings = saved.settings
                settings.normalize()
                if migrated { persist() }
            }
        } catch { persistenceError = "Không đọc được cấu hình: \(error.localizedDescription)" }
    }

    var connected: Bool { snapshot?.connected == true }
    var canApply: Bool {
        connected && snapshot?.gameRunning == true && !(snapshot?.sessionID?.isEmpty ?? true) && !busy && unsupportedKeys.isEmpty
    }
    var isApplied: Bool {
        connected && snapshot?.gameRunning == true && confirmedRevision == revision && snapshot?.appliedRevision == revision
    }
    var unsupportedKeys: [String] {
        guard let snapshot, snapshot.connected else { return [] }
        let supported = Set(snapshot.supportedKeys)
        return settings.preferenceValues.keys.filter { !supported.contains($0) }.sorted()
    }
    func supports(_ key: String) -> Bool { snapshot?.supportedKeys.contains(key) == true }
    func setFlag(_ key: String, _ value: Bool) {
        guard Feature.all.contains(where: { $0.key == key }) else { return }
        reloadProfileIfChanged()
        settings.flags[key] = value
        changed()
    }
    func setCamera(_ value: Double) { reloadProfileIfChanged(); settings.cameraScale = value; changed() }
    func setCameraEnabled(_ value: Bool) { reloadProfileIfChanged(); settings.cameraEnabled = value; changed() }
    func setEspReadHz(_ value: Int) { reloadProfileIfChanged(); settings.espReadHz = value; changed() }
    func prepareCombinedCheck() {
        reloadProfileIfChanged()
        guard persistenceError == nil else { return }
        for feature in Feature.all where feature.group == .esp {
            settings.flags[feature.key] = feature.key != "DoroCheat.Reference.R1.Unseen"
        }
        settings.flags["reports.enabled"] = true
        changed()
    }
    func setSkin(hero: UInt32, skin: Int?) {
        reloadProfileIfChanged()
        if let skin, let entry = snapshot?.heroes.first(where: { $0.id == hero }),
           entry.skins.contains(where: { $0.id == skin }) {
            settings.selectedSkins[String(hero)] = skin
        } else if skin == nil { settings.selectedSkins.removeValue(forKey: String(hero)) }
        changed()
    }
    func reset() { settings = ControlSettings(); changed() }
    // Import edits made by the independent HUD without treating them as a game
    // acknowledgement. Revisions change even while the backend is disconnected.
    func reloadProfileIfChanged() {
        guard FileManager.default.fileExists(atPath: profileURL.path) else { return }
        do {
            let data = try Data(contentsOf: profileURL)
            guard data.count <= 131072 else { throw BackendError.unavailable("Cấu hình quá lớn.") }
            let (saved, migrated) = try ProfileCodec.decode(data)
            guard saved.schemaVersion == 1 else { throw BackendError.unavailable("Phiên bản cấu hình không hỗ trợ.") }
            var imported = saved.settings; imported.normalize()
            if imported != settings {
                settings = imported; revision = UUID().uuidString; confirmedRevision = nil
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
        persist()
    }
    private func persist() {
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(SavedProfile(schemaVersion: 1, settings: settings))
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
    private func requestStatus(action: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let reply = try await backend.send(action: action, revision: nil, settings: nil)
            backendTrace = await backend.exchangeTrace()
            guard reply.ok, reply.protocolVersion == 1, reply.snapshot?.protocolVersion == 1 else {
                throw BackendError.unavailable(reply.message)
            }
            accept(reply.snapshot)
            message = reply.message
        } catch {
            backendTrace = await backend.exchangeTrace()
            disconnected(error)
        }
    }
    func apply() async {
        guard canApply else { return }
        let sentRevision = revision, sentSettings = settings, sentSession = snapshot?.sessionID
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
                message = "Backend chưa xác nhận áp dụng cấu hình; chưa đánh dấu thành công."
                return
            }
            confirmedRevision = sentRevision
            message = revision == sentRevision ? "Backend đã xác nhận áp dụng cấu hình." : "Đã áp dụng bản trước; còn thay đổi chưa áp dụng."
        } catch {
            backendTrace = await backend.exchangeTrace()
            disconnected(error)
        }
    }
    private func accept(_ value: BackendSnapshot?) {
        if value?.sessionID != snapshot?.sessionID || value?.connected != true || value?.gameRunning != true {
            confirmedRevision = nil
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
            let overlay: OverlayState?
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let diagnostics = Diagnostics(schemaVersion: 1, settings: settings, revision: revision,
                                      confirmedRevision: confirmedRevision, snapshot: snapshot, message: message,
                                      appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                                      appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                                      backendExchange: backendTrace, overlay: overlayState)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HeroControl-diagnostics.json")
        try encoder.encode(diagnostics).write(to: url, options: .atomic)
        return url
    }
}
