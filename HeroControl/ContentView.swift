import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var store: ControlStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showReset = false
    @State private var showConnection = false
    @State private var showKernelCheck = false
    @State private var shareItem: ShareItem?
    @State private var exportError: String?
    private let accent = Color(red: 0.39, green: 0.88, blue: 0.78)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statusCard
                    groupPicker
                    controls
                    if let error = store.persistenceError { Text(error).foregroundStyle(.orange).font(.footnote) }
                    if let error = exportError { Text(error).foregroundStyle(.orange).font(.footnote) }
                    Button { Task { await store.apply() } } label: {
                        HStack {
                            if store.busy { ProgressView().tint(.black) }
                            Text(store.isApplied ? "ĐÃ ÁP DỤNG" : "ÁP DỤNG VÀO GAME").fontWeight(.bold)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }.padding(18).foregroundStyle(.black)
                            .background(store.canApply ? accent : Color.gray, in: RoundedRectangle(cornerRadius: 16))
                    }.disabled(!store.canApply)
                    Text("Các thay đổi được lưu cục bộ. Chỉ trạng thái xác nhận từ backend mới được hiển thị là đã áp dụng.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(20)
            }
            .background(Color(red: 0.04, green: 0.055, blue: 0.08))
            .navigationTitle("Hero Control")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Thông tin kết nối", systemImage: "network") { showConnection = true }
                        Button("Chẩn đoán kernel", systemImage: "stethoscope") { showKernelCheck = true }
                        Button("Xuất cấu hình & chẩn đoán", systemImage: "square.and.arrow.up") {
                            do { shareItem = ShareItem(url: try store.exportDiagnostics()); exportError = nil }
                            catch { exportError = error.localizedDescription }
                        }
                        Button("Đặt lại cấu hình", systemImage: "arrow.counterclockwise", role: .destructive) { showReset = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .confirmationDialog("Đặt lại tất cả lựa chọn trên ứng dụng?", isPresented: $showReset, titleVisibility: .visible) {
                Button("Đặt lại", role: .destructive) { store.reset() }
            } message: { Text("Muốn đưa game về cấu hình này, cần bấm Áp dụng sau khi kết nối backend.") }
            .sheet(isPresented: $showConnection) { connectionDetails }
            .sheet(isPresented: $showKernelCheck) { KernelDiagnosticsView(store: store) }
            .sheet(item: $shareItem) { ActivitySheet(items: [$0.url]) }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await store.refresh()
                    do { try await Task.sleep(nanoseconds: 3_000_000_000) }
                    catch { break }
                }
            }
        }.tint(accent)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: store.connected ? "link" : "link.badge.plus")
                Text(store.connected ? "BACKEND ĐÃ KẾT NỐI GAME" : (store.snapshot?.diagnostics != nil ? "BACKEND CHẨN ĐOÁN" : "CHƯA KẾT NỐI BACKEND")).font(.caption.bold())
                Spacer()
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(store.busy).accessibilityLabel("Kiểm tra kết nối")
            }.foregroundStyle(store.connected ? accent : .orange)
            Text(store.isApplied ? "Cấu hình đã được xác nhận" : "Cấu hình đang chuẩn bị").font(.title3.bold())
            Text(store.message).font(.subheadline).foregroundStyle(.secondary)
            if let snapshot = store.snapshot {
                Label(snapshot.gameInspectionAvailable == false ? "Chưa tích hợp bộ nhận diện game" : (snapshot.gameRunning ? "Game đang chạy" : "Chưa tìm thấy game"),
                      systemImage: snapshot.gameRunning ? "gamecontroller.fill" : "gamecontroller")
                    .font(.caption).foregroundStyle(.secondary)
                if !store.unsupportedKeys.isEmpty {
                    Text("Backend chưa hỗ trợ đủ \(store.unsupportedKeys.count) khóa cấu hình. Xem Thông tin kết nối.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Button("Xem chẩn đoán kernel") { showKernelCheck = true }.font(.subheadline.bold())
        }.padding(18).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))
    }

    private var groupPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(FeatureGroup.allCases) { group in
                    Button { store.selectedGroup = group } label: {
                        Label(group.rawValue, systemImage: group.symbol)
                            .font(.subheadline.bold()).padding(.horizontal, 14).padding(.vertical, 12)
                            .foregroundStyle(store.selectedGroup == group ? .black : .white)
                            .background(store.selectedGroup == group ? accent : .white.opacity(0.07), in: Capsule())
                    }
                }
            }
        }
    }

    @ViewBuilder private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(store.selectedGroup.rawValue.uppercased()).font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(Feature.all.filter { $0.group == store.selectedGroup }) { feature in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(feature.title, isOn: Binding(
                        get: { store.settings.flags[feature.key] ?? false },
                        set: { store.setFlag(feature.key, $0) }))
                    if store.connected && !store.supports(feature.key) {
                        Text("Backend chưa hỗ trợ").font(.caption).foregroundStyle(.orange)
                    }
                }
                Divider().overlay(.white.opacity(0.05))
            }
            switch store.selectedGroup {
            case .camera: cameraControls
            case .skins: skinControls
            case .reports: reportControls
            case .esp:
                Text("Box, icon, HP và minimap cần dữ liệu cùng bộ vẽ overlay do backend cung cấp.")
                    .font(.footnote).foregroundStyle(.secondary)
            case .style:
                Text("Lựa chọn này cần backend áp dụng vào tài nguyên và hành vi game lúc chạy.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.padding(18).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 20))
    }

    private var cameraControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("CAMERA SCALE").font(.headline)
                Spacer()
                Text(String(format: "%.2f×", store.settings.cameraScale)).font(.title2.monospacedDigit()).foregroundStyle(accent)
            }
            Slider(value: Binding(get: { store.settings.cameraScale }, set: { store.setCamera($0) }), in: 1...2.3, step: 0.01)
                .accessibilityLabel("Hệ số camera")
            HStack { Text("1.00×"); Spacer(); Text("2.30×") }.font(.caption).foregroundStyle(.secondary)
            Button("Đặt lại camera 1.00×") { store.setCamera(1) }.buttonStyle(.bordered)
        }
    }

    private var skinControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("CHỌN SKIN THEO TƯỚNG").font(.caption.bold()).foregroundStyle(.secondary)
            if let heroes = store.snapshot?.heroes, !heroes.isEmpty {
                ForEach(heroes) { hero in
                    Picker(hero.name, selection: Binding<Int>(
                        get: { store.settings.selectedSkins[String(hero.id)] ?? -1 },
                        set: { store.setSkin(hero: hero.id, skin: $0 < 0 ? nil : $0) })) {
                        Text("Theo game").tag(-1)
                        ForEach(hero.skins) { skin in Text(skin.name).tag(skin.id) }
                    }.pickerStyle(.menu)
                }
            } else {
                ContentUnavailableView("Chưa có danh sách tướng", systemImage: "person.crop.square",
                    description: Text("Danh sách thật sẽ xuất hiện khi backend đọc được dữ liệu game."))
            }
            if !store.settings.selectedSkins.isEmpty {
                Text("Đã lưu \(store.settings.selectedSkins.count) lựa chọn skin.").font(.caption).foregroundStyle(.secondary)
                Button("Xóa các lựa chọn skin") {
                    for key in Array(store.settings.selectedSkins.keys) {
                        if let hero = UInt32(key) { store.setSkin(hero: hero, skin: nil) }
                    }
                }.buttonStyle(.bordered)
            }
        }
    }

    private var reportControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let reports = store.snapshot?.reports, !reports.isEmpty {
                ForEach(reports) { report in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(report.time).font(.caption.monospaced()).foregroundStyle(accent)
                        Text(report.information).fontWeight(.medium)
                        Text(report.reason).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Divider()
                }
            } else {
                ContentUnavailableView("Chưa có bản ghi", systemImage: "list.bullet.rectangle",
                    description: Text("Chưa nhận dữ liệu từ backend. Trạng thái này không có nghĩa là không có tố cáo."))
            }
        }
    }

    private var connectionDetails: some View {
        NavigationStack {
            List {
                Section("Thiết bị") {
                    LabeledContent("Thiết bị", value: UIDevice.current.model)
                    LabeledContent("Hệ điều hành", value: UIDevice.current.systemVersion)
                }
                Section("Kết nối") {
                    LabeledContent("Backend", value: store.snapshot?.backendName ?? "Chưa cài")
                    LabeledContent("Game", value: store.snapshot?.gameVersion ?? "Chưa xác định")
                    LabeledContent("Phiên", value: store.snapshot?.sessionID ?? "Không có")
                    Text(store.message).font(.footnote)
                }
                if !store.unsupportedKeys.isEmpty {
                    Section("Khóa backend còn thiếu") {
                        ForEach(store.unsupportedKeys, id: \.self) { Text($0).font(.caption.monospaced()) }
                    }
                }
                Section("Bản ứng dụng này") {
                    Text("Menu độc lập; không chứa trình khai thác kernel, bộ vẽ overlay trên game hoặc mã sửa HeroSkin. Backend tương thích phải được tích hợp riêng.")
                }
            }.navigationTitle("Thông tin kết nối")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Đóng") { showConnection = false } } }
        }
    }
}

private struct ShareItem: Identifiable { let id = UUID(); let url: URL }
private struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
