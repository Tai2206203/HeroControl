import Foundation
import Combine
import Darwin

struct OverlayState: Codable {
    let schemaVersion: Int?
    let phase: String?
    let generation: String?
    let pid: Int?
    let euid: Int?
    let menuOpen: Bool?
    let hiddenForLock: Bool?
    let touchEvents: Int?
    let settingsError: String?
    let camera: CameraStatus?
    let esp: EspStatus?
    let espLastSample: EspStatus?
    let reports: FeatureCheckStatus?
    let displayLimitHz: Int?
    let overlayDrawFPS: Double?
    var hiddenForCapture: Bool? = nil
    var captureLayerConfigured: Bool? = nil
    var captureScope: String? = nil
    var captureProtected: Bool? = nil
    var secureHostAvailable: Bool? = nil
    var screenCaptured: Bool? = nil
    var iconCount: Int? = nil
}

struct EspStatus: Codable {
    let code: String
    let message: String
    let memoryStatus: Int?
    let targetCount: Int?
    let projectedCount: Int?
    let listCount: Int?
    let matricesValid: Bool?
    let matrixStage: Int?
    let viewMode: Int?
    let projectionDirty: Int?
    let nativeCamera: String?
    let pid: Int?
    let timestamp: String?
    let hasHostPosition: Bool?
    let hostX: Double?
    let hostZ: Double?
    let targets: [EspTargetStatus]?
    let requestedReadHz: Int?
    let measuredReadHz: Double?
    let hiddenClientCount: Int?
    let logicAvailable: Bool?
    let logicStage: Int?
    let logicTargetCount: Int?
    let logicFrameNumber: UInt32?
    let cooldownKnownCount: Int?
    let sampleUptime: Double?
    let readSampleUptime: Double?
    let sampleRetained: Bool?
    let sampleAge: Double?
    let holdWindowSeconds: Double?
}

struct EspTargetStatus: Codable {
    let objectID: UInt32
    let heroID: Int
    let hp: Int
    let maxHP: Int
    let worldX: Double
    let worldZ: Double
    let x: Double
    let feetY: Double
    let headY: Double
    let visible: Bool
    let onScreen: Bool
    let cooldowns: [Int]
    let hpKnown: Bool?
    let hpCurrentKnown: Bool?
    let positionSource: String?
    let cooldownSource: String?
    var maxHPSource: String? = nil
    let positionFrame: UInt32?
}

struct CameraStatus: Codable {
    let code: String
    let message: String
    let scale: Double?
    let sourceZoom: Double?
    let writtenZoom: Double?
    let writeCount: Int?
    let memoryStatus: Int?
    let pid: Int?
    let timestamp: String?
    let cameraClass: String?
    let cameraObject: String?
    let mobaObject: String?
}

private struct OverlayReply: Decodable {
    let ok: Bool
    let message: String
    let state: OverlayState
}

// Independent of the kernel/game backend. A persistent HUD must never be
// launched through a request that waits for it to exit on the main thread.
private actor OverlayClient {
    private typealias Request = @convention(c) (UnsafePointer<CChar>) -> UnsafePointer<CChar>?
    private typealias Release = @convention(c) (UnsafePointer<CChar>) -> Void
    private var handle: UnsafeMutableRawPointer?
    private var request: Request?
    private var release: Release?

    func send(action: String, directory: URL, profile: URL) throws -> (OverlayState, String, String, Bool) {
        if request == nil {
            let path = Bundle.main.bundleURL.appendingPathComponent("Frameworks/HeroOverlayBridge.dylib").path
            guard let library = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
                throw BackendError.unavailable("Không nạp được bộ điều khiển nút nổi: \(dlerror().map { String(cString: $0) } ?? "dlopen failed")")
            }
            guard let entry = dlsym(library, "hc_overlay_request"), let free = dlsym(library, "hc_overlay_release") else {
                dlclose(library)
                throw BackendError.unavailable("Bộ điều khiển nút nổi thiếu ABI.")
            }
            handle = library
            request = unsafeBitCast(entry, to: Request.self)
            release = unsafeBitCast(free, to: Release.self)
        }
        let data = try JSONSerialization.data(withJSONObject: ["action": action, "directory": directory.path, "profile": profile.path])
        guard let text = String(data: data, encoding: .utf8), let request, let release,
              let result = text.withCString({ request($0) }) else {
            throw BackendError.unavailable("Bộ điều khiển nút nổi không trả kết quả.")
        }
        defer { release(result) }
        let length = strnlen(result, 4 * 1024 * 1024 + 1)
        guard length <= 4 * 1024 * 1024 else { throw BackendError.unavailable("Báo cáo nút nổi vượt giới hạn 4 MiB.") }
        let response = Data(bytes: result, count: length)
        let reply = try JSONDecoder().decode(OverlayReply.self, from: response)
        return (reply.state, reply.message, String(decoding: response, as: UTF8.self), reply.ok)
    }
}

@MainActor
final class OverlayController: ObservableObject {
    @Published private(set) var state: OverlayState?
    @Published private(set) var message = "Đang chuẩn bị nút nổi…"
    @Published private(set) var failure: String?
    @Published private(set) var busy = false
    @Published private(set) var report = "{}"
    private let client = OverlayClient()
    private var profile: URL?
    private var failureReport: String?
    private let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HeroOverlay", isDirectory: true)

    var running: Bool { state?.phase == "visible" }

    func start(profile: URL) async {
        self.profile = profile
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch { failure = error.localizedDescription; return }
        await perform("start")
    }
    func refresh() async { await perform("status") }
    func stop() async { await perform("stop"); await refresh() }
    func toggle() async { await perform("toggle") }
    func restart() async {
        guard let profile else { return }
        await start(profile: profile)
    }
    private func perform(_ action: String) async {
        guard !busy, let profile else { return }
        busy = true
        defer { busy = false }
#if targetEnvironment(simulator)
        message = "Simulator chỉ xem được giao diện; nút nổi hệ thống cần iPhone."
        return
#else
        do {
            let (state, message, report, ok) = try await client.send(action: action, directory: directory, profile: profile)
            self.state = state; self.message = message; self.report = report
            if !ok { failure = message; failureReport = report }
            else if action == "start" || running { failure = nil; failureReport = nil }
        } catch { failure = error.localizedDescription; message = error.localizedDescription }
#endif
    }
    func exportReport() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HeroControl-overlay.json")
        // Polling status must not discard the startup log of the failed launch.
        try Data((failureReport ?? report).utf8).write(to: url, options: .atomic)
        return url
    }
}
