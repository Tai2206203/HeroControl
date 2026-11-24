import XCTest
@testable import HeroControl

final class ControlTests: XCTestCase {
    func testLegacyNumericProfileFlagsAreRepairedWithoutWeakeningWireTypes() throws {
        let old = Data(#"{"schemaVersion":1,"settings":{"flags":{"__ifxEnemyEspEnabledV1":1,"DoroCheat.Reference.R1.HP":0},"cameraScale":1.6,"cameraEnabled":1,"selectedSkins":{}}}"#.utf8)
        let (profile, migrated) = try ProfileCodec.decode(old)
        XCTAssertTrue(migrated)
        XCTAssertEqual(profile.settings.cameraEnabled, true)
        XCTAssertEqual(profile.settings.cameraScale, 1.6)
        XCTAssertEqual(profile.settings.flags["__ifxEnemyEspEnabledV1"], true)
        XCTAssertEqual(profile.settings.flags["DoroCheat.Reference.R1.HP"], false)
        let valid = try JSONEncoder().encode(profile)
        XCTAssertFalse(try ProfileCodec.decode(valid).1)
        XCTAssertThrowsError(try ProfileCodec.decode(Data(String(decoding: old, as: UTF8.self).replacingOccurrences(of: ":1,\"Doro", with: ":2,\"Doro").utf8)))
    }
    @MainActor
    func testCombinedCheckEnablesCameraAndEspButDoesNotClaimReports() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ControlStore(directory: folder)
        store.prepareCombinedCheck()
        XCTAssertEqual(store.settings.cameraEnabled, true)
        XCTAssertEqual(store.settings.cameraScale, 1.5)
        XCTAssertEqual(store.settings.flags["__ifxEnemyEspEnabledV1"], true)
        XCTAssertEqual(store.settings.flags["DoroCheat.Reference.R1.Unseen"], false)
        XCTAssertEqual(store.settings.flags["reports.enabled"], false)
        XCTAssertFalse(store.isApplied)
    }
    @MainActor
    func testLegacyProfileDoesNotEnableCameraAndCanPersistExplicitOptIn() throws {
        let old = Data(#"{"flags":{},"cameraScale":1.6,"selectedSkins":{}}"#.utf8)
        let decoded = try JSONDecoder().decode(ControlSettings.self, from: old)
        XCTAssertNotEqual(decoded.cameraEnabled, true)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ControlStore(directory: folder)
        store.setCameraEnabled(true)
        XCTAssertEqual(ControlStore(directory: folder).settings.cameraEnabled, true)
        store.setCameraEnabled(false)
        XCTAssertEqual(ControlStore(directory: folder).settings.cameraEnabled, false)
    }
    func testProfileRoundTripAndPreferenceMapping() throws {
        var profile = ControlSettings()
        profile.flags["DoroCheat.Reference.R1.HP"] = true
        profile.cameraScale = 1.75
        profile.selectedSkins["123"] = 7
        let loaded = try JSONDecoder().decode(ControlSettings.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(profile, loaded)
        XCTAssertEqual(loaded.preferenceValues["DoroCheat.Reference.R1.HP"], 1)
        XCTAssertEqual(loaded.preferenceValues[Feature.cameraKey], 1.75)
        XCTAssertEqual(loaded.preferenceValues["DoroCheat.Style.SelectedSkin.123"], 7)
    }

    func testInvalidImportedValuesAreNormalized() {
        var profile = ControlSettings()
        profile.cameraScale = .infinity
        profile.flags["unknown"] = true
        profile.selectedSkins = ["bad": 3, "1": -1, "2": 7, "4294967296": 1]
        profile.normalize()
        XCTAssertEqual(profile.cameraScale, 1)
        XCTAssertNil(profile.flags["unknown"])
        XCTAssertEqual(profile.selectedSkins, ["2": 7])
        profile.cameraScale = 7
        profile.normalize()
        XCTAssertEqual(profile.cameraScale, 2.3)
    }

    @MainActor
    func testOverlayProfileEditInvalidatesAcknowledgementAndPreservesOtherControls() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = TestBackend()
        let store = ControlStore(directory: directory, backend: backend)
        await store.refresh()
        await backend.setAcknowledgement(true)
        await store.apply()
        XCTAssertTrue(store.isApplied)
        let oldRevision = store.revision
        let url = try XCTUnwrap(store.prepareOverlayProfile())
        var external = store.settings
        external.flags["DoroCheat.Reference.R1.HP"] = true
        external.cameraScale = 2.04
        try JSONEncoder().encode(SavedProfile(schemaVersion: 1, settings: external)).write(to: url, options: .atomic)
        // A user changes another control before the next foreground poll. The
        // store must import the HUD edit first rather than overwrite the file.
        store.setFlag("DoroCheat.Reference.R1.Box", true)
        XCTAssertEqual(store.settings.cameraScale, 2.04)
        XCTAssertEqual(store.settings.flags["DoroCheat.Reference.R1.HP"], true)
        XCTAssertEqual(store.settings.flags["DoroCheat.Reference.R1.Box"], true)
        XCTAssertNotEqual(store.revision, oldRevision)
        XCTAssertNil(store.confirmedRevision)
        XCTAssertFalse(store.isApplied)
        let persisted = try JSONDecoder().decode(SavedProfile.self, from: Data(contentsOf: url))
        XCTAssertEqual(persisted.settings, store.settings)
    }

    @MainActor
    func testCorruptOverlayProfileIsReportedWithoutOverwritingIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ControlStore(directory: directory)
        let url = try XCTUnwrap(store.prepareOverlayProfile())
        let corrupt = Data("{not json".utf8)
        try corrupt.write(to: url, options: .atomic)
        store.reloadProfileIfChanged()
        XCTAssertNotNil(store.persistenceError)
        XCTAssertNil(store.prepareOverlayProfile())
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertFalse(store.isApplied)
    }

    @MainActor
    func testSavedConfigurationIsNotReportedAsApplied() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ControlStore(directory: directory)
        first.setFlag("__ifxEnemyEspEnabledV1", true)
        first.setCamera(1.6)
        let restored = ControlStore(directory: directory)
        XCTAssertEqual(restored.settings, first.settings)
        XCTAssertFalse(restored.isApplied)
        XCTAssertFalse(restored.canApply)
        await restored.apply()
        XCTAssertNil(restored.confirmedRevision)
        await restored.refresh()
        XCTAssertFalse(restored.connected)
        XCTAssertFalse(restored.isApplied)
        XCTAssertFalse(restored.message.isEmpty)
    }

    @MainActor
    func testApplyRequiresExactAcknowledgementAndSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = TestBackend()
        let store = ControlStore(directory: directory, backend: backend)
        await store.refresh()
        XCTAssertTrue(store.canApply)
        await backend.setAcknowledgement(false)
        await store.apply()
        XCTAssertFalse(store.isApplied)
        await backend.setAcknowledgement(true)
        await store.apply()
        XCTAssertTrue(store.isApplied)
        store.setCamera(1.9)
        XCTAssertFalse(store.isApplied)
        await store.apply()
        XCTAssertTrue(store.isApplied)
        await backend.restartGame()
        await store.refresh()
        XCTAssertFalse(store.isApplied)
    }

    @MainActor
    func testRestartDuringApplyCannotAcknowledgeOldSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = TestBackend()
        let store = ControlStore(directory: directory, backend: backend)
        await store.refresh()
        await backend.setAcknowledgement(true)
        await backend.setRestartDuringApply()
        await store.apply()
        XCTAssertFalse(store.isApplied)
        XCTAssertNil(store.confirmedRevision)
    }

    func testDiagnosticsSnapshotDecodesWithoutPretendingGameConnection() throws {
        let json = #"{"protocolVersion":1,"backendName":"diagnostics","connected":false,"gameRunning":false,"supportedKeys":[],"heroes":[],"reports":[],"message":"test","gameInspectionAvailable":false,"diagnostics":{"schemaVersion":1,"timestamp":"test","system":"Darwin","machine":"iPhone11,8","uid":501,"euid":501,"kernelProbeRequested":true,"kernelReadVerified":false,"code":"root_helper_required","summary":"test","checkedPaths":[],"symbolsFound":["kbase","kread"]}}"#
        let snapshot = try JSONDecoder().decode(BackendSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.diagnostics?.euid, 501)
        XCTAssertEqual(snapshot.diagnostics?.code, "root_helper_required")
        XCTAssertFalse(snapshot.connected)
        XCTAssertFalse(snapshot.gameInspectionAvailable ?? true)
    }

    func testNumericOKRegressionReportsCodingPath() {
        let numeric = #"{"protocolVersion":1,"ok":1,"message":"old broken native response"}"#
        XCTAssertThrowsError(try BackendReplyDecoder.decode(Data(numeric.utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("$.ok"), error.localizedDescription)
        }
    }

    func testMissingAndInvalidNestedFieldsReportExactPath() {
        let missing = #"{"protocolVersion":1,"ok":true}"#
        XCTAssertThrowsError(try BackendReplyDecoder.decode(Data(missing.utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("$.message"), error.localizedDescription)
        }
        let invalid = #"{"protocolVersion":1,"ok":true,"message":"test","snapshot":{"protocolVersion":1,"backendName":"test","connected":0}}"#
        XCTAssertThrowsError(try BackendReplyDecoder.decode(Data(invalid.utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("$.snapshot.connected"), error.localizedDescription)
        }
    }

    func testNativeTraceIsAvailableThroughConcreteAndProtocolCalls() async {
        let missingLibrary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("missing.dylib")
        let backend = NativeBackend(libraryURL: missingLibrary)
        let client: any BackendClient = backend
        do {
            _ = try await client.send(action: "status", revision: nil, settings: nil)
            XCTFail("Loading a nonexistent dylib must fail")
        } catch {
            let concreteTrace = await backend.exchangeTrace()
            let protocolTrace = await client.exchangeTrace()
            XCTAssertEqual(concreteTrace?.stage, "load")
            XCTAssertEqual(protocolTrace?.stage, "load")
            XCTAssertEqual(protocolTrace?.libraryPath, missingLibrary.path)
            XCTAssertEqual(protocolTrace?.action, "status")
        }
    }
}

private actor TestBackend: BackendClient {
    func exchangeTrace() async -> BackendExchangeTrace? { nil }
    private var acknowledge = false
    private var session = "test-session-1"
    private var applied: String?
    private var restartDuringApply = false
    func setAcknowledgement(_ value: Bool) { acknowledge = value }
    func restartGame() { session = "test-session-2"; applied = nil }
    func setRestartDuringApply() { restartDuringApply = true }
    func send(action: String, revision: String?, settings: ControlSettings?) async throws -> BackendReply {
        if action == "apply" {
            if restartDuringApply { session = "new-session-during-apply" }
            applied = acknowledge ? revision : "wrong-revision"
        }
        let snapshot = BackendSnapshot(protocolVersion: 1, backendName: "Unit test only", connected: true,
            gameRunning: true, sessionID: session, gameVersion: "test", supportedKeys: Array(ControlSettings().preferenceValues.keys),
            appliedRevision: applied, heroes: [], reports: [], message: "test")
        return BackendReply(protocolVersion: 1, ok: true, message: "test", snapshot: snapshot)
    }
}
