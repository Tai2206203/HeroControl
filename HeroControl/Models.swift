import Foundation

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
        .init(key: "DoroCheat.Reference.R1.Box", title: "ESP Box", group: .esp),
        .init(key: "DoroCheat.Reference.R1.Icon", title: "ESP Icon", group: .esp),
        .init(key: "DoroCheat.Reference.R1.HP", title: "ESP HP", group: .esp),
        .init(key: "DoroCheat.Reference.R1.Map", title: "ESP Minimap", group: .esp),
        .init(key: "DoroCheat.Reference.R1.Unseen", title: "Unseen only", group: .esp),
        .init(key: "DoroCheat.Reference.R1.Check", title: "ESP Check / kỹ năng", group: .esp),
        .init(key: "DoroCheat.Style.Buttons", title: "Skin Buttons", group: .style),
        .init(key: "DoroCheat.Style.Banner", title: "Kill Banner", group: .style),
        .init(key: "DoroCheat.Style.Skin", title: "Mod Skin", group: .skins),
        .init(key: "DoroCheat.Style.BeforeMatch", title: "Before Match", group: .skins),
        .init(key: "DoroCheat.Style.LiveChange", title: "Live Change", group: .skins),
        .init(key: "reports.enabled", title: "Theo dõi tố cáo", group: .reports)
    ]
    static let cameraKey = "DoroCheat.Reference.R2.CameraScale"
}

struct ControlSettings: Codable, Equatable {
    var flags: [String: Bool] = Dictionary(uniqueKeysWithValues: Feature.all.map { ($0.key, false) })
    var cameraScale: Double = 1
    var selectedSkins: [String: Int] = [:]
    mutating func normalize() {
        flags = Dictionary(uniqueKeysWithValues: Feature.all.map { ($0.key, flags[$0.key] ?? false) })
        cameraScale = cameraScale.isFinite ? min(2.3, max(1, cameraScale)) : 1
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
}
