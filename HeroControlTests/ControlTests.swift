import XCTest
@testable import HeroControl

final class ControlTests: XCTestCase {
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
}

private actor TestBackend: BackendClient {
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
