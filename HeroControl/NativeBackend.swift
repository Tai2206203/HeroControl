import Foundation
import Darwin

enum BackendError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let text): return text }
    }
}

protocol BackendClient: Sendable {
    func send(action: String, revision: String?, settings: ControlSettings?) async throws -> BackendReply
    func exchangeTrace() async -> BackendExchangeTrace?
}

extension BackendClient {
    func exchangeTrace() async -> BackendExchangeTrace? { nil }
}

enum BackendReplyDecoder {
    static func decode(_ data: Data) throws -> BackendReply {
        do { return try JSONDecoder().decode(BackendReply.self, from: data) }
        catch let error as DecodingError {
            let detail: String
            switch error {
            case .typeMismatch(let type, let context):
                detail = "\(path(context.codingPath)): cần \(type). \(context.debugDescription)"
            case .keyNotFound(let key, let context):
                detail = "\(path(context.codingPath + [key])): thiếu trường bắt buộc."
            case .valueNotFound(let type, let context):
                detail = "\(path(context.codingPath)): cần \(type), nhận null."
            case .dataCorrupted(let context):
                detail = "\(path(context.codingPath)): \(context.debugDescription)"
            @unknown default: detail = String(describing: error)
            }
            throw BackendError.unavailable("Backend JSON không hợp lệ tại \(detail)")
        }
    }
    private static func path(_ keys: [CodingKey]) -> String {
        keys.reduce("$") { result, key in
            if let index = key.intValue { return result + "[\(index)]" }
            return result + "." + key.stringValue
        }
    }
}

// Serializes all native requests. This adapter does not implement a kernel exploit.
actor NativeBackend: BackendClient {
    private typealias VersionFunction = @convention(c) () -> UInt32
    private typealias RequestFunction = @convention(c) (UnsafePointer<CChar>) -> UnsafePointer<CChar>?
    private typealias ReleaseFunction = @convention(c) (UnsafePointer<CChar>) -> Void
    private var handle: UnsafeMutableRawPointer?
    private var requestFunction: RequestFunction?
    private var releaseFunction: ReleaseFunction?
    private let maxResponseSize = 4 * 1024 * 1024
    private var trace: BackendExchangeTrace?
    private let libraryURL: URL
    init(libraryURL: URL = Bundle.main.bundleURL.appendingPathComponent("Frameworks/HeroBackend.dylib")) {
        self.libraryURL = libraryURL
    }
    func exchangeTrace() -> BackendExchangeTrace? { trace }

    private func load() throws {
        if requestFunction != nil { return }
        let path = libraryURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw BackendError.unavailable("Chưa có backend kernel/game. Các lựa chọn hiện chỉ được lưu trên ứng dụng.")
        }
        guard let library = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            let detail = dlerror().map { String(cString: $0) } ?? "dlopen failed"
            throw BackendError.unavailable("Không nạp được backend: \(detail)")
        }
        guard let versionSymbol = dlsym(library, "hc_backend_api_version"),
              let requestSymbol = dlsym(library, "hc_backend_request"),
              let releaseSymbol = dlsym(library, "hc_backend_release") else {
            dlclose(library)
            throw BackendError.unavailable("Backend thiếu các hàm ABI bắt buộc.")
        }
        let version = unsafeBitCast(versionSymbol, to: VersionFunction.self)
        guard version() == 1 else {
            dlclose(library)
            throw BackendError.unavailable("Phiên bản ABI backend không tương thích.")
        }
        handle = library
        requestFunction = unsafeBitCast(requestSymbol, to: RequestFunction.self)
        releaseFunction = unsafeBitCast(releaseSymbol, to: ReleaseFunction.self)
    }

    func send(action: String, revision: String? = nil, settings: ControlSettings? = nil) throws -> BackendReply {
        trace = BackendExchangeTrace(action: action,
            libraryPath: libraryURL.path, stage: "load")
        try load()
        trace?.stage = "request"
        let request = BackendRequest(action: action, revision: revision, settings: settings,
                                     preferenceValues: settings?.preferenceValues)
        let data = try JSONEncoder().encode(request)
        guard let text = String(data: data, encoding: .utf8),
              let function = requestFunction, let release = releaseFunction else {
            throw BackendError.unavailable("Không tạo được yêu cầu backend.")
        }
        guard let response = text.withCString({ function($0) }) else {
            throw BackendError.unavailable("Backend không trả kết quả.")
        }
        defer { release(response) }
        trace?.stage = "read-response"
        let length = strnlen(response, maxResponseSize + 1)
        trace?.responseByteCount = length
        guard length <= maxResponseSize else {
            throw BackendError.unavailable("Phản hồi backend vượt giới hạn 4 MiB.")
        }
        let responseData = Data(bytes: response, count: length)
        trace?.stage = "decode"
        trace?.responseTruncated = length > 65536
        trace?.rawResponse = String(decoding: responseData.prefix(65536), as: UTF8.self)
        trace?.responsePrefixHex = responseData.prefix(64).map { String(format: "%02x", $0) }.joined()
        let reply: BackendReply
        do { reply = try BackendReplyDecoder.decode(responseData) }
        catch {
            trace?.decodingError = error.localizedDescription
            throw error
        }
        guard reply.protocolVersion == 1, (reply.snapshot?.protocolVersion ?? 1) == 1 else {
            throw BackendError.unavailable("Phiên bản giao thức backend không tương thích.")
        }
        guard reply.ok else { throw BackendError.unavailable(reply.message) }
        trace?.stage = "complete"
        return reply
    }
}
