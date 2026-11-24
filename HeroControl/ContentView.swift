import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var store: ControlStore
    @ObservedObject var overlay: OverlayController
    @Environment(\.scenePhase) private var scenePhase
    @State private var showReset = false
    @State private var showConnection = false
    @State private var showKernelCheck = false
    @State private var shareItem: ShareItem?
    @State private var exportError: String?
    private let accent = Color(red: 0.39, green: 0.88, blue: 0.78)
    private var reportStatus: FeatureCheckStatus? {
        store.snapshot?.runtime?.reports ?? store.snapshot?.runtime?.historicalReports ?? overlay.state?.reports
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    overlayCard
                    runtimeCard
                    combinedCheck
                    statusCard
                    groupPicker
                    controls
                    if let error = store.persistenceError { Text(error).foregroundStyle(.orange).font(.footnote) }
                    if let error = exportError { Text(error).foregroundStyle(.orange).font(.footnote) }
                    if store.settings.gameRuntimeEnabled == true || store.selectedGroup == .style || store.selectedGroup == .skins {
                      Button { Task { await store.apply() } } label: {
                        HStack {
                            if store.busy { ProgressView().tint(.black) }
                            Text(store.isApplied ? "ĐÃ ÁP DỤNG" : "ÁP DỤNG VÀO GAME").fontWeight(.bold)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }.padding(18).foregroundStyle(.black)
                            .background(store.canApply ? accent : Color.gray, in: RoundedRectangle(cornerRadius: 16))
                      }.disabled(!store.canApply)
                    }
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
                            do { shareItem = ShareItem(url: try store.exportDiagnostics(overlayState: overlay.state)); exportError = nil }
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
            .sheet(isPresented: $showKernelCheck) { KernelDiagnosticsView(store: store, overlay: overlay) }
            .sheet(item: $shareItem) { ActivitySheet(items: [$0.url]) }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await store.refresh()
                    await overlay.refresh()
                    do { try await Task.sleep(nanoseconds: 3_000_000_000) }
                    catch { break }
                }
            }
        }.tint(accent)
    }

    private var runtimeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("CHỨC NĂNG GAME GỐC", systemImage: "puzzlepiece.extension").font(.headline)
            Text("Ảnh tướng, minimap game, kỹ năng, skin và truy vấn tố cáo dùng bộ xử lý trong game đi kèm TIPA.")
            Text(store.snapshot?.runtime?.message ?? "Cài adapter khi game đang mở và khớp phiên bản. Sau đó đóng hoàn toàn, mở lại game rồi quay về đây kiểm tra.")
                .foregroundStyle(.secondary)
            if let phase = store.snapshot?.runtime?.phase { Text("Trạng thái: \(phase)").font(.caption.monospaced()) }
            if let result = store.runtimeOperationMessage { Text("Lần cài/gỡ gần nhất: \(result)").font(.caption) }
            if let error = store.snapshot?.runtime?.catalogError { Text("Danh mục skin: \(error)").foregroundStyle(.orange) }
            Button("Cài / cập nhật adapter game") { Task { await store.installRuntime() } }
                .disabled(store.busy || store.persistenceError != nil)
            Button("Kiểm tra adapter") { Task { await store.refresh() } }.disabled(store.busy)
            Button("Gỡ adapter — cần mở lại game", role: .destructive) { Task { await store.removeRuntime() } }.disabled(store.busy)
            Text("Cần môi trường jailbreak có bộ nạp tweak tương thích. Nạp patch và đọc lại cấu hình chưa xác minh hiệu ứng hình ảnh hoặc độ đầy đủ lịch sử máy chủ.")
                .font(.caption).foregroundStyle(.orange)
        }.font(.footnote).padding(16).background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
    }

    private var combinedCheck: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("KIỂM CHỨNG ĐỒNG THỜI", systemImage: "checklist").font(.headline)
            if store.settings.gameRuntimeEnabled == true {
                Text("Adapter: \(store.snapshot?.runtime?.phase ?? "chưa có phản hồi")")
                Text("ESP do game vẽ bằng sprite và minimap gốc; bộ đếm đọc/vẽ ngoài không áp dụng.")
                Text("Xác nhận cấu hình: \(store.snapshot?.runtime?.acknowledgement ?? "chưa xác nhận")")
            } else { Group {
                Text("Camera: \(overlay.state?.camera?.code ?? "chưa chạy") • lần ghi: \(overlay.state?.camera?.writeCount ?? 0)")
                Text("ESP: \(overlay.state?.esp?.code ?? "chưa chạy") • chiếu được: \(overlay.state?.esp?.projectedCount ?? 0)/\(overlay.state?.esp?.targetCount ?? 0)")
                Text(String(format: "Đọc ESP: %.1f Hz • lượt vẽ: %.1f/s • màn hình tối đa %ld Hz", overlay.state?.esp?.measuredReadHz ?? 0, overlay.state?.overlayDrawFPS ?? 0, overlay.state?.displayLimitHz ?? 60))
                Text("Nguồn logic: \(overlay.state?.esp?.logicAvailable == true ? "đã đọc" : "chưa đọc") • mục tiêu logic: \(overlay.state?.esp?.logicTargetCount ?? 0) • bước: \(overlay.state?.esp?.logicStage ?? 0)")
                Text("Cooldown đã đọc: \(overlay.state?.esp?.cooldownKnownCount ?? 0) slot")
            } }
            if let esp = overlay.state?.esp, let stage = esp.matrixStage {
                Text("Ma trận: bước \(stage)/7 • chế độ view: \(esp.viewMode ?? -1) • projection dirty: \(esp.projectionDirty ?? -1)")
            }
            if let sample = overlay.state?.espLastSample {
                Text("Mẫu trong trận gần nhất: \(sample.projectedCount ?? 0)/\(sample.targetCount ?? 0) • \(sample.timestamp ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Tố cáo: \(reportStatus?.code ?? "chưa nhận dữ liệu") • \(reportStatus?.records?.count ?? 0) bản ghi")
            if let error = overlay.state?.settingsError, !error.isEmpty { Text(error).foregroundStyle(.orange) }
            Button("Bật ESP + truy vấn tố cáo (giữ camera)") {
                store.prepareCombinedCheck()
                Task {
                    if !overlay.running, let profile = store.prepareOverlayProfile() { await overlay.start(profile: profile) }
                    await store.inspectGame()
                    await overlay.refresh()
                }
            }.disabled(store.busy || overlay.busy)
            Text("Sau khi bật, vào trận tập và thu menu. Chưa có kiểm chứng hình ảnh tự động; số lần ghi và số mục tiêu không thay thế việc đối chiếu trực tiếp.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Xuất kết quả chung", systemImage: "square.and.arrow.up") {
                Task {
                    await overlay.refresh()
                    do {
                        guard let state = overlay.state else { throw BackendError.unavailable("Chưa có báo cáo nút nổi. Bật nút nổi rồi xuất lại.") }
                        shareItem = ShareItem(url: try store.exportDiagnostics(overlayState: state)); exportError = nil
                    } catch { exportError = error.localizedDescription }
                }
            }
        }.font(.footnote).padding(16).background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
    }

    private var overlayCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(overlay.running ? "Nút nổi Hero Control đang chạy" : "Nút nổi Hero Control", systemImage: "circle.circle")
                .font(.headline).foregroundStyle(accent)
            Text(overlay.failure ?? overlay.message).font(.footnote)
                .foregroundStyle(overlay.failure == nil ? Color.secondary : .orange)
            if let camera = overlay.state?.camera, camera.code != "camera_disabled" {
                Label("Camera xa: \(camera.message)", systemImage: "camera").font(.footnote)
            }
            Text("Chạm HC để mở/thu menu; kéo để di chuyển. Khi dùng adapter, nút nổi chuyển cấu hình đến game.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("Chế độ tránh chặn màn hình: chạm menu nổi có thể đồng thời chạm ứng dụng phía dưới. Nên mở menu khi đang ở Hero Control và thu menu trước khi vào game.")
                .font(.footnote).foregroundStyle(.orange)
            HStack {
                if overlay.running {
                    Button("Mở/thu menu") { Task { await overlay.toggle() } }
                } else {
                    Button("Bật nút nổi") { Task {
                        if let profile = store.prepareOverlayProfile() { await overlay.start(profile: profile) }
                    } }
                }
                Spacer()
                Button("Tắt nút nổi", role: .destructive) { Task { await overlay.stop() } }
                if overlay.busy { ProgressView() }
            }.disabled(overlay.busy)
            Button("Xuất báo cáo nút nổi", systemImage: "square.and.arrow.up") {
                do { shareItem = ShareItem(url: try overlay.exportReport()); exportError = nil }
                catch { exportError = error.localizedDescription }
            }.font(.footnote)
        }.padding(16).background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
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
            if let game = store.snapshot?.gameInspection {
                VStack(alignment: .leading, spacing: 6) {
                    Text("KIỂM TRA TRUY CẬP GAME").font(.caption.bold())
                    Text(game.message).font(.footnote)
                    if let pid = game.pid { Text("PID: \(pid) • Phiên bản: \(game.gameVersion ?? "unknown")").font(.caption.monospaced()) }
                    if let status = game.taskPortStatus { Text("Quyền đọc tiến trình: mã \(status)").font(.caption) }
                    if let error = game.taskPortError, game.taskPortStatus != 0 { Text(error).font(.caption.monospaced()) }
                    Text("Đọc bộ nhớ: \(game.memoryReadVerified ? "đã xác minh" : "chưa xác minh") • Dump: \(game.unityUUID == nil ? "chưa kiểm tra" : game.moduleMatchesDump ? "khớp" : "không khớp")")
                        .font(.caption)
                    Text("Lần kiểm tra: \(game.timestamp)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let snapshot = store.snapshot {
                Label(snapshot.gameInspectionAvailable == false ? "Chưa xác minh tiến trình game" : (snapshot.gameRunning ? "Đã quan sát thấy game ở lần kiểm tra" : "Chưa quan sát thấy game ở lần kiểm tra"),
                      systemImage: snapshot.gameRunning ? "gamecontroller.fill" : "gamecontroller")
                    .font(.caption).foregroundStyle(.secondary)
                if !store.unsupportedKeys.isEmpty {
                    Text("Backend chưa hỗ trợ đủ \(store.unsupportedKeys.count) khóa cấu hình. Xem Thông tin kết nối.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Button("Xem chẩn đoán kernel") { showKernelCheck = true }.font(.subheadline.bold())
            Button("Kiểm tra truy cập game", systemImage: "gamecontroller") { Task { await store.inspectGame() } }
                .font(.subheadline.bold()).disabled(store.busy)
            Text("Mở Liên Quân vào sảnh, quay lại đây và bấm kiểm tra. Sau đó dùng Xuất cấu hình & chẩn đoán để gửi kết quả.")
                .font(.caption).foregroundStyle(.secondary)
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
                        .disabled(!overlay.running && store.settings.gameRuntimeEnabled != true)
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
                if store.settings.gameRuntimeEnabled != true {
                    Picker("Nhịp đọc ESP ngoài", selection: Binding(get: { store.settings.espReadHz ?? 60 }, set: { store.setEspReadHz($0) })) {
                        Text("60 Hz").tag(60)
                        Text("120 Hz").tag(120)
                    }.pickerStyle(.segmented)
                    Text("Nhịp đọc này chỉ dùng cho bộ đọc ngoài. iPhone XR hiển thị tối đa 60 Hz.")
                        .font(.footnote).foregroundStyle(.orange)
                } else {
                    Text("ESP cập nhật theo callback render gốc của game. Cấu hình đọc ngoài 60/120 Hz không điều khiển adapter.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("ESP Icon dùng ảnh sprite tướng; ESP Minimap cập nhật minimap của game qua adapter. Radar riêng đã bỏ. Cài adapter để sử dụng các chức năng này.")
                    .font(.footnote).foregroundStyle(.secondary)
            case .style:
                Text("Lựa chọn này cần backend áp dụng vào tài nguyên và hành vi game lúc chạy.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.padding(18).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 20))
    }

    private var cameraControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Bật camera xa", isOn: Binding(get: { store.settings.cameraEnabled == true }, set: { store.setCameraEnabled($0) }))
                .disabled(!overlay.running && store.settings.gameRuntimeEnabled != true)
            HStack {
                Text("CAMERA SCALE").font(.headline)
                Spacer()
                Text(String(format: "%.2f×", store.settings.cameraScale)).font(.title2.monospacedDigit()).foregroundStyle(accent)
            }
            Slider(value: Binding(get: { store.settings.cameraScale }, set: { store.setCamera($0) }), in: 1...2.3, step: 0.01)
                .accessibilityLabel("Hệ số camera")
            HStack { Text("1.00×"); Spacer(); Text("2.30×") }.font(.caption).foregroundStyle(.secondary)
            Button("Đặt lại camera 1.00×") { store.setCamera(1) }.buttonStyle(.bordered)
            Text(overlay.state?.camera?.message ?? "Mở nút nổi, bật camera xa rồi vào trận tập để thử.")
                .font(.footnote).foregroundStyle(.secondary)
            if let report = overlay.state?.camera {
                Text(report.code).font(.caption.monospaced())
                if let source = report.sourceZoom, let written = report.writtenZoom {
                    Text(String(format: "Giá trị game: %.3f → ghi: %.3f", source, written)).font(.caption)
                }
            }
            Text("Nút nổi đồng bộ cấu hình khi đang chạy; hoặc bấm Áp dụng. Reports truy vấn lịch sử máy chủ qua adapter và giữ nhật ký theo tài khoản.")
                .font(.footnote).foregroundStyle(.secondary)
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
            Text(reportStatus?.message ?? "Cài adapter và bật truy vấn lịch sử tố cáo.")
            if store.snapshot?.runtime?.historicalReports != nil {
                Text("Dữ liệu lần cuối: \(store.snapshot?.runtime?.timestamp ?? "chưa rõ"). Adapter hiện không phản hồi trực tiếp; đây là lịch sử đã lưu.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let stage = overlay.state?.reports?.stage { Text("Bước đọc: \(stage)/9").font(.caption.monospaced()) }
            Text("Nguồn: lịch sử máy chủ trả về cho người chơi đã thu thập và nhật ký đã lưu. Có giữ các bản ghi lịch sử ban đầu. Giao thức hiện chưa chứng minh bao phủ mọi tố cáo trên máy chủ; danh sách rỗng không có nghĩa là không bị tố cáo.")
                .font(.footnote).foregroundStyle(.orange)
            if let report = reportStatus {
                Text("Yêu cầu: \(report.sentRequestCount ?? 0) • phản hồi: \(report.receivedResponseCount ?? 0) • người chơi: \(report.candidateCount ?? 0)")
                    .font(.caption.monospaced())
                if report.transportFault == true { Text("Luồng phản hồi hết hạn. Đăng nhập lại trước khi tiếp tục truy vấn.").foregroundStyle(.orange) }
                if report.recordsTruncated == true { Text("Báo cáo giới hạn 2048 bản ghi; nhật ký đầy đủ được giữ trong dữ liệu game.").foregroundStyle(.orange) }
            }
            if let reports = reportStatus?.records, !reports.isEmpty {
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
                    description: Text("Chưa nhận được bản ghi từ máy chủ/nhật ký. Kiểm tra trạng thái adapter và số phản hồi."))
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
                    Text("TIPA đi kèm adapter nạp bản vá tham khảo trong bộ nhớ game, dùng sprite/minimap và mạng của game. Không thay các tệp HeroSkin gốc. Chức năng chỉ được xác minh sau kiểm thử trên thiết bị.")
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
