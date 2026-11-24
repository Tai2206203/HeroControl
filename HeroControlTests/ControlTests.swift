import XCTest
@testable import HeroControl

final class ControlTests: XCTestCase {
    @MainActor
    func testCorruptProfileCannotBeOverwrittenBySetters() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ControlStore(directory: folder)
        let url = try XCTUnwrap(store.prepareOverlayProfile())
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: url, options: .atomic)
        store.setCamera(2)
        store.setCameraEnabled(true)
        store.setFlag("DoroCheat.Reference.R1.Icon", true)
        XCTAssertNotNil(store.persistenceError)
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }
    @MainActor
    func testProfileRevisionIsSharedWithNativeRuntime() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ControlStore(directory: folder)
        store.setCamera(1.8)
        let url = try XCTUnwrap(store.prepareOverlayProfile())
        var saved = try JSONDecoder().decode(SavedProfile.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.revision, store.revision)
        saved.revision = "native-edit-revision"
        try JSONEncoder().encode(saved).write(to: url, options: .atomic)
        store.reloadProfileIfChanged()
        XCTAssertEqual(store.revision, "native-edit-revision")
        XCTAssertEqual(ControlStore(directory: folder).revision, store.revision)
    }
    func testRuntimeHistoryMetadataDecodesWithoutClaimingCompleteness() throws {
        let data = Data(#"{"phase":"active","responding":true,"runtimeBuild":"20","effectsVerified":false,"reports":{"code":"server_history_monitoring","message":"waiting","querySupported":true,"completeHistoryGuaranteed":false,"sentRequestCount":5,"receivedResponseCount":4,"candidateCount":10,"records":[]}}"#.utf8)
        let state = try JSONDecoder().decode(GameRuntimeStatus.self, from: data)
        XCTAssertEqual(state.reports?.querySupported, true)
        XCTAssertEqual(state.reports?.completeHistoryGuaranteed, false)
        XCTAssertEqual(state.reports?.receivedResponseCount, 4)
        XCTAssertEqual(state.effectsVerified, false)
    }
    @MainActor
    func testQueuedApplyWaitsForSameSessionGameAcknowledgement() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let backend = TestBackend()
        let store = ControlStore(directory: folder, backend: backend)
        await store.refresh()
        await backend.deferNextAcknowledgement()
        await store.apply()
        XCTAssertFalse(store.isApplied)
        await backend.completeQueuedAcknowledgement()
        await store.refresh()
        XCTAssertTrue(store.isApplied)
    }
    func testBackgroundRuntimeRetainsHistoricalReportsSeparately() throws {
        let data = Data(#"{"phase":"stale","responding":false,"timestamp":"sample-time","historicalReports":{"code":"server_history_monitoring","message":"previous response","records":[{"id":"1","time":"sample","information":"notice","reason":"reason"}]}}"#.utf8)
        let state = try JSONDecoder().decode(GameRuntimeStatus.self, from: data)
        XCTAssertNil(state.reports)
        XCTAssertEqual(state.historicalReports?.records?.count, 1)
        XCTAssertEqual(state.responding, false)
        XCTAssertNoThrow(try JSONDecoder().decode(GameRuntimeStatus.self, from: Data(#"{"phase":"not_loaded","responding":false}"#.utf8)))
    }
    func testLogicEspSourceAndRateArePreservedInDiagnosticExport() throws {
        let data = Data(#"{"code":"esp_frame_read","message":"sample","logicAvailable":true,"logicStage":8,"logicTargetCount":1,"requestedReadHz":120,"measuredReadHz":115.5,"targets":[{"objectID":99,"heroID":123,"hp":800,"maxHP":0,"worldX":2,"worldZ":-10,"x":0.6,"feetY":0.5,"headY":0.36,"visible":false,"onScreen":true,"cooldowns":[-1,-1,-1],"hpKnown":false,"hpCurrentKnown":true,"positionSource":"logic","positionFrame":10}]}"#.utf8)
        let sample = try JSONDecoder().decode(EspStatus.self, from: data)
        let exported = try JSONDecoder().decode(EspStatus.self, from: JSONEncoder().encode(sample))
        XCTAssertEqual(exported.logicAvailable, true)
        XCTAssertEqual(exported.requestedReadHz, 120)
        XCTAssertEqual(exported.measuredReadHz, 115.5)
        XCTAssertEqual(exported.targets?.first?.positionSource, "logic")
        XCTAssertEqual(exported.targets?.first?.visible, false)
        XCTAssertEqual(exported.targets?.first?.hpCurrentKnown, true)
    }
    func testEspRateRemainsCompatibleWithOldProfiles() throws {
        var settings = try JSONDecoder().decode(ControlSettings.self, from: Data(#"{"flags":{},"cameraScale":1.5,"selectedSkins":{}}"#.utf8))
        XCTAssertNil(settings.espReadHz)
        settings.espReadHz = 120
        let decoded = try JSONDecoder().decode(ControlSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.espReadHz, 120)
        settings.espReadHz = 1000; settings.normalize()
        XCTAssertEqual(settings.espReadHz, 60)
    }
    func testHistoricalEspSampleIsExportedSeparatelyFromLiveFailure() throws {
        let payload = Data(#"{"phase":"visible","esp":{"code":"esp_access_unavailable","message":"no live game","targets":[]},"espLastSample":{"code":"esp_matrices_pending","message":"waiting","pid":7832,"timestamp":"2026-11-24T02:58:00Z","listCount":10,"targetCount":3,"projectedCount":0,"matrixStage":4,"viewMode":1,"projectionDirty":0,"targets":[]}}"#.utf8)
        let state = try JSONDecoder().decode(OverlayState.self, from: payload)
        XCTAssertEqual(state.esp?.code, "esp_access_unavailable")
        XCTAssertEqual(state.espLastSample?.targetCount, 3)
        XCTAssertEqual(state.espLastSample?.viewMode, 1)
        let exported = try JSONDecoder().decode(OverlayState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(exported.espLastSample?.pid, 7832)
        XCTAssertEqual(exported.esp?.targets?.count, 0)
        let empty = try JSONDecoder().decode(OverlayState.self, from: Data(#"{"espLastSample":null}"#.utf8))
        XCTAssertNil(empty.espLastSample)
    }
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
    func testCombinedCheckPreservesWorkingCameraAndEnablesEspAndMailReader() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ControlStore(directory: folder)
        store.setCamera(2.04)
        store.setCameraEnabled(true)
        store.prepareCombinedCheck()
        XCTAssertEqual(store.settings.cameraEnabled, true)
        XCTAssertEqual(store.settings.cameraScale, 2.04)
        XCTAssertEqual(store.settings.flags["__ifxEnemyEspEnabledV1"], true)
        XCTAssertEqual(store.settings.flags["DoroCheat.Reference.R1.Unseen"], false)
        XCTAssertEqual(store.settings.flags["reports.enabled"], true)
        XCTAssertFalse(store.isApplied)
    }
    func testMailCacheStatusDoesNotClaimServerHistoryQuery() throws {
        let json = Data(#"{"code":"complaint_mail_cache_read","message":"cache only","available":true,"stage":9,"accountID":"9007199254740993","source":"cached_game_mail","querySupported":false,"records":[{"id":"mail:42","time":"2023-11-14T22:13:20Z","information":"notice","reason":"ChgCreditType=7"}]}"#.utf8)
        let report = try JSONDecoder().decode(FeatureCheckStatus.self, from: json)
        XCTAssertEqual(report.accountID, "9007199254740993")
        XCTAssertEqual(report.querySupported, false)
        XCTAssertEqual(report.records?.count, 1)
        XCTAssertEqual(report.source, "cached_game_mail")
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
    private var deferred = false
    private var queuedRevision: String?
    func deferNextAcknowledgement() { deferred = true }
    func completeQueuedAcknowledgement() { applied = queuedRevision; deferred = false }
    func setAcknowledgement(_ value: Bool) { acknowledge = value }
    func restartGame() { session = "test-session-2"; applied = nil }
    func setRestartDuringApply() { restartDuringApply = true }
    func send(action: String, revision: String?, settings: ControlSettings?) async throws -> BackendReply {
        if action == "apply" {
            if restartDuringApply { session = "new-session-during-apply" }
            if deferred { queuedRevision = revision }
            else { applied = acknowledge ? revision : "wrong-revision" }
        }
        let snapshot = BackendSnapshot(protocolVersion: 1, backendName: "Unit test only", connected: !deferred,
            gameRunning: true, sessionID: session, gameVersion: "test", supportedKeys: Array(ControlSettings().preferenceValues.keys),
            appliedRevision: applied, heroes: [], reports: [], message: "test")
        return BackendReply(protocolVersion: 1, ok: true, message: "test", snapshot: snapshot)
    }
}
