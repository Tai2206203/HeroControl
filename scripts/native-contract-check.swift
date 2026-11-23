import Foundation

// Builds alongside the production Models.swift and NativeBackend.swift on the
// macOS runner. Exercises the real Objective-C -> C ABI -> JSON -> Swift path.
@main
struct NativeContractCheck {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Expected dylib path") }
        let backend = NativeBackend(libraryURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let reply = try await backend.send(action: "status")
        guard reply.ok, let snapshot = reply.snapshot, let report = snapshot.diagnostics,
              !snapshot.connected, !snapshot.gameRunning, snapshot.gameInspectionAvailable == false,
              snapshot.supportedKeys.isEmpty, !report.kernelProbeRequested, !report.kernelReadVerified else {
            fatalError("Native diagnostics response violated the Swift contract")
        }
        let trace = await backend.exchangeTrace()
        guard trace?.stage == "complete", trace?.rawResponse != nil else { fatalError("Missing response trace") }
        do {
            _ = try await backend.send(action: "apply", revision: "must-not-ack", settings: ControlSettings())
            fatalError("Diagnostics backend unexpectedly accepted apply")
        } catch is BackendError { /* Expected refusal. */ }

        let numeric = Data(#"{"protocolVersion":1,"ok":1,"message":"old broken response"}"#.utf8)
        do {
            _ = try BackendReplyDecoder.decode(numeric)
            fatalError("Numeric JSON ok was accepted as a boolean")
        } catch {
            guard error.localizedDescription.contains("$.ok") else { throw error }
        }
        print("Production C ABI -> JSON -> Swift contract passed; numeric ok regression rejected at $.ok.")
    }
}
