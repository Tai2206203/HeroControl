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
}

private actor TestBackend: BackendClient {
    private var acknowledge = false
    private var session = "test-session-1"
    private var applied: String?
    func setAcknowledgement(_ value: Bool) { acknowledge = value }
    func restartGame() { session = "test-session-2"; applied = nil }
    func send(action: String, revision: String?, settings: ControlSettings?) async throws -> BackendReply {
        if action == "apply" { applied = acknowledge ? revision : "wrong-revision" }
        let snapshot = BackendSnapshot(protocolVersion: 1, backendName: "Unit test only", connected: true,
            gameRunning: true, sessionID: session, gameVersion: "test", supportedKeys: Array(ControlSettings().preferenceValues.keys),
            appliedRevision: applied, heroes: [], reports: [], message: "test")
        return BackendReply(protocolVersion: 1, ok: true, message: "test", snapshot: snapshot)
    }
}
