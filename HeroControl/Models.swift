import Foundation
import CoreFoundation

// Repair only the known profile-writing bug from the old native toggle. Wire
// replies still use strict Bool decoding (numeric `ok` remains invalid).
enum ProfileCodec {
    static func decode(_ data: Data) throws -> (SavedProfile, Bool) {
        guard data.count <= 131072 else { throw CocoaError(.fileReadTooLarge) }
        var changed = false
        var payload = data
        if var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           var settings = root["settings"] as? [String: Any], var flags = settings["flags"] as? [String: Any] {
            for key in Feature.all.map(\.key) {
                if let n = flags[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == 0 || n.doubleValue == 1 {
                    flags[key] = n.doubleValue == 1; changed = true
                }
            }
            if let n = settings["cameraEnabled"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == 0 || n.doubleValue == 1 {
                settings["cameraEnabled"] = n.doubleValue == 1; changed = true
            }
            if changed {
                settings["flags"] = flags; root["settings"] = settings
                payload = try JSONSerialization.data(withJSONObject: root)
            }
        }
        return (try JSONDecoder().decode(SavedProfile.self, from: payload), changed)
    }
}

enum FeatureGroup: String, CaseIterable, Identifiable {
    case esp = "ESP", camera = "Camera", style = "Style", skins = "Skins", reports = "Reports"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .esp: return "viewfinder"
        case .camera: return "camera"
        case .style: return "paintbrush"
        case .skins: return "person.crop.square"
        case .reports: return "list.bullet.rectangle"
        }
    }
}

struct Feature: Identifiable {
    let key: String
    let title: String
    let group: FeatureGroup
    var id: String { key }
    static let all: [Feature] = [
        .init(key: "__ifxEnemyEspEnabledV1", title: "Enable ESP", group: .esp),
        .init(key: "HeroControl.ESP.HeroID", title: "ESP ID tướng địch", group: .esp),
        .init(key: "DoroCheat.Reference.R1.Box", title: "ESP Box", group: .esp),
        .init(key: "DoroCheat.Reference.R1.Icon", title: "ESP Icon (ảnh tướng)", group: .esp),
        .init(key: "DoroCheat.Reference.R1.HP", title: "ESP HP", group: .esp),
        .init(key: "DoroCheat.Reference.R1.Map", title: "ESP Minimap", group: .esp),
        .init(key: "DoroCheat.Reference.R1.Unseen", title: "Unseen only", group: .esp),
        .init(key: "DoroCheat.Reference.R1.Check", title: "ESP Check / kỹ năng", group: .esp),
        .init(key: "DoroCheat.Style.Buttons", title: "Skin Buttons", group: .style),
        .init(key: "DoroCheat.Style.Banner", title: "Kill Banner", group: .style),
        .init(key: "DoroCheat.Style.Skin", title: "Mod Skin", group: .skins),
        .init(key: "DoroCheat.Style.BeforeMatch", title: "Before Match", group: .skins),
        .init(key: "DoroCheat.Style.LiveChange", title: "Live Change", group: .skins),
        .init(key: "reports.enabled", title: "Truy vấn lịch sử tố cáo", group: .reports)
    ]
    static let cameraKey = "DoroCheat.Reference.R2.CameraScale"
}

struct ControlSettings: Codable, Equatable {
    var flags: [String: Bool] = Dictionary(uniqueKeysWithValues: Feature.all.map { ($0.key, false) })
    var cameraScale: Double = 1
    var selectedSkins: [String: Int] = [:]
    var cameraEnabled: Bool? = nil
    var espReadHz: Int? = nil
    var gameRuntimeEnabled: Bool? = nil
    var espCaptureProtected: Bool? = nil
    var minimapX: Double? = nil
    var minimapY: Double? = nil
    var minimapSize: Double? = nil
    var minimapIconSize: Double? = nil
    var espBoxWidthScale: Double? = nil
    var espBoxHeightScale: Double? = nil
    var espIconSize: Double? = nil
    var minimapWorldExtent: Double? = nil
    var minimapRotated: Bool? = nil
    mutating func normalize() {
        flags = Dictionary(uniqueKeysWithValues: Feature.all.map { ($0.key, flags[$0.key] ?? false) })
        cameraScale = cameraScale.isFinite ? min(2.3, max(1, cameraScale)) : 1
        if let hz = espReadHz, hz != 60 && hz != 120 { espReadHz = 60 }
        if let v = minimapX { minimapX = v.isFinite ? min(1, max(0, v)) : 0.015 }
        if let v = minimapY { minimapY = v.isFinite ? min(1, max(0, v)) : 0.02 }
        if let v = minimapSize { minimapSize = v.isFinite ? min(240, max(80, v)) : 150 }
        if let v = minimapIconSize { minimapIconSize = v.isFinite ? min(40, max(8, v)) : 20 }
        if let v = espBoxWidthScale { espBoxWidthScale = v.isFinite ? min(3, max(0.5, v)) : 1 }
        if let v = espBoxHeightScale { espBoxHeightScale = v.isFinite ? min(3, max(0.5, v)) : 1 }
        if let v = espIconSize { espIconSize = v.isFinite ? min(64, max(12, v)) : 32 }
        if let v = minimapWorldExtent { minimapWorldExtent = v.isFinite ? min(200, max(30, v)) : 60 }
        selectedSkins = selectedSkins.filter { UInt32($0.key) != nil && $0.value >= 0 && $0.value <= Int(UInt32.max) }
    }
    var preferenceValues: [String: Double] {
        var result = Dictionary(uniqueKeysWithValues: flags.map { ($0.key, $0.value ? 1.0 : 0.0) })
        result[Feature.cameraKey] = cameraScale
        for (hero, skin) in selectedSkins { result["DoroCheat.Style.SelectedSkin.\(hero)"] = Double(skin) }
        return result
    }
}

struct SkinChoice: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
}

struct HeroChoice: Codable, Identifiable, Hashable {
    let id: UInt32
    let name: String
    let skins: [SkinChoice]
}

struct ReportRecord: Codable, Identifiable {
    let id: String
    let time: String
    let information: String
    let reason: String
}

struct BackendSnapshot: Codable {
    let protocolVersion: Int
    let backendName: String
    let connected: Bool
    let gameRunning: Bool
    let sessionID: String?
    let gameVersion: String?
    let supportedKeys: [String]
    let appliedRevision: String?
    let heroes: [HeroChoice]
    let reports: [ReportRecord]
    let message: String
    var diagnostics: KernelDiagnostics? = nil
    var gameInspectionAvailable: Bool? = nil
    var gameInspection: GameInspection? = nil
    var gameProbeDiagnostics: KernelDiagnostics? = nil
    var runtime: GameRuntimeStatus? = nil
    var runtimeDiagnostics: KernelDiagnostics? = nil
}

struct FeatureCheckStatus: Codable {
    let code: String
    let message: String
    let available: Bool?
    let stage: Int?
    let tablesRead: Int?
    let accountID: String?
    let source: String?
    let querySupported: Bool?
    var completeHistoryGuaranteed: Bool? = nil
    var sentRequestCount: Int? = nil
    var receivedResponseCount: Int? = nil
    var candidateCount: Int? = nil
    var transportFault: Bool? = nil
    var recordsTruncated: Bool? = nil
    var retainedRecordCount: Int? = nil
    var serverResultCode: Int? = nil
    let readBudgetExceeded: Bool?
    let records: [ReportRecord]?
    let timestamp: String?
}

struct GameRuntimeStatus: Codable {
    let phase: String?
    let code: String?
    let message: String?
    let responding: Bool?
    let runtimeBuild: String?
    let generation: String?
    let pid: Int?
    let sessionID: String?
    let appliedRevision: String?
    let acknowledgement: String?
    let effectsVerified: Bool?
    let reports: FeatureCheckStatus?
    let historicalReports: FeatureCheckStatus?
    let timestamp: String?
    let catalogError: String?
    let directory: String?
}

struct GameInspection: Codable {
    let schemaVersion: Int
    let timestamp: String
    let bundleID: String
    let gameRunning: Bool
    let processScanSucceeded: Bool
    let memoryReadVerified: Bool
    let moduleMatchesDump: Bool
    let expectedUnityUUID: String
    let code: String
    let message: String
    let pid: Int?
    let gameVersion: String?
    let taskPortStatus: Int?
    let taskPortError: String?
    let dyldInfoStatus: Int?
    let unityUUID: String?
    let unityBase: String?
}

struct KernelLibraryCheck: Codable {
    let path: String
    let visible: Bool
    let status: Int
    let loadMessage: String?
}

struct KernelDiagnostics: Codable {
    let schemaVersion: Int
    let timestamp: String
    let system: String
    let machine: String
    let uid: UInt32
    let euid: UInt32
    let kernelProbeRequested: Bool
    let kernelReadVerified: Bool
    let code: String
    let summary: String
    let checkedPaths: [KernelLibraryCheck]
    let loadedLibrary: String?
    let symbolsFound: [String]
    let kernelBaseStatus: Int?
    let kernelReadStatus: Int?
    let headerMagic: String?
    let jailbreakRoots: [String]?
    let resolverNotes: [String]?
    let providerChecks: [KernelLibraryCheck]?
    let entitlementChecks: [String: Bool]?
    let callerEntitlements: [String: Bool]?
    let executionContext: String?
    let appUID: UInt32?
    let appEUID: UInt32?
    let helperStage: String?
    let helperSpawnStatus: Int?
    let helperExitStatus: Int?
    let helperSignal: Int?
    let helperError: String?
    let helperCollectedFDs: [Int]?
    let helperStdoutByteCount: Int?
    let helperStderrByteCount: Int?
    let helperStdoutPreview: String?
    let helperDecodeError: String?
    let helperReportedEUID: UInt32?
    var loaderCandidates: [String]? = nil
    var installStage: String? = nil
    var installPath: String? = nil
    var installErrorDomain: String? = nil
    var installErrorCode: Int? = nil
    var installPOSIXError: Int? = nil
}

struct BackendRequest: Encodable {
    let protocolVersion = 1
    let action: String
    let revision: String?
    let settings: ControlSettings?
    let preferenceValues: [String: Double]?
}

struct BackendReply: Decodable {
    let protocolVersion: Int
    let ok: Bool
    let message: String
    let snapshot: BackendSnapshot?
}

struct SavedProfile: Codable {
    let schemaVersion: Int
    let settings: ControlSettings
    var revision: String? = nil
}

struct BackendExchangeTrace: Codable {
    let action: String
    let libraryPath: String
    var stage: String
    var responseByteCount: Int?
    var rawResponse: String?
    var responseTruncated: Bool?
    var responsePrefixHex: String?
    var decodingError: String?
}

// A missing name stays explicit; IDs remain usable as future image filenames.
struct HeroIconEntry: Identifiable {
    let id: UInt32
    let name: String
    var imageFile: String { "\(id).png" }
    static func collect(heroes: [HeroChoice], observedIDs: [Int]) -> [HeroIconEntry] {
        var values: [UInt32: String] = [:]
        for hero in heroes where hero.id > 0 { values[hero.id] = hero.name }
        for number in observedIDs {
            if let id = UInt32(exactly: number), id > 0, values[id] == nil { values[id] = "" }
        }
        return values.keys.sorted().map { HeroIconEntry(id: $0, name: values[$0] ?? "") }
    }
    static func csv(_ entries: [HeroIconEntry]) -> String {
        func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return "\u{FEFF}hero_id,hero_name,image_file\r\n" + entries.map {
            "\($0.id),\(quote($0.name)),\(quote($0.imageFile))\r\n"
        }.joined()
    }
}
