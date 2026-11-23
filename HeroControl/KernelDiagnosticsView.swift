import SwiftUI
import UIKit

struct KernelDiagnosticsView: View {
    @ObservedObject var store: ControlStore
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var exportedFile: URL?
    private var terminalCommand: String {
        let path = Bundle.main.bundleURL.appendingPathComponent("Tools/hero-kernel-check").path
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "' --kernel-read"
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Kiểm tra thư viện và quyền truy cập thực tế. Đọc kernel thành công cũng chưa có nghĩa các chức năng game đã hoạt động.")
                        .font(.subheadline)
                    Button { Task { await store.diagnose() } } label: {
                        Label(store.busy ? "Đang kiểm tra…" : "Kiểm tra ngay", systemImage: "stethoscope")
                    }.disabled(store.busy)
                    Text("Khi bấm kiểm tra, ứng dụng yêu cầu khởi chạy helper root bằng quyền persona do trình cài đặt/jailbreak cấp. Nếu bị từ chối, báo cáo sẽ ghi mã lỗi.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let report = store.snapshot?.diagnostics {
                    Section("Kết quả") {
                        LabeledContent("Hệ thống", value: "\(report.system) / \(report.machine)")
                        LabeledContent("UID / EUID", value: "\(report.uid) / \(report.euid)")
                        if let context = report.executionContext { LabeledContent("Tiến trình kiểm tra", value: context) }
                        if let appEUID = report.appEUID { LabeledContent("EUID ứng dụng", value: String(appEUID)) }
                        LabeledContent("Mã kết quả", value: report.code)
                        LabeledContent("Đọc kernel", value: report.kernelReadVerified ? "Đã xác minh" : "Chưa xác minh")
                        Text(report.summary)
                        if let library = report.loadedLibrary { Text(library).font(.caption.monospaced()).textSelection(.enabled) }
                        if let status = report.kernelBaseStatus { LabeledContent("kbase status", value: String(status)) }
                        if let status = report.kernelReadStatus { LabeledContent("kread status", value: String(status)) }
                        if let magic = report.headerMagic { LabeledContent("Header", value: magic) }
                        Text(report.timestamp).font(.caption).foregroundStyle(.secondary)
                    }
                    if let entitlements = report.callerEntitlements ?? report.entitlementChecks, !entitlements.isEmpty {
                        Section("Entitlement đọc được từ chữ ký") {
                            ForEach(entitlements.keys.sorted(), id: \.self) { key in
                                VStack(alignment: .leading) {
                                    Text(key).font(.caption.monospaced())
                                    Text(entitlements[key] == true ? "Có trong chữ ký" : "Không có / false").font(.caption)
                                }
                            }
                            Text("Có entitlement trong chữ ký chưa đủ để kết luận hệ thống đã cấp quyền; kết quả truy cập phía trên mới là kiểm chứng thực tế.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let stage = report.helperStage {
                        Section("Helper root") {
                            LabeledContent("Bước", value: stage)
                            if let value = report.helperSpawnStatus { LabeledContent("Spawn status", value: String(value)) }
                            if let value = report.helperExitStatus { LabeledContent("Exit status", value: String(value)) }
                            if let value = report.helperSignal { LabeledContent("Signal", value: String(value)) }
                            if let text = report.helperError { Text(text).font(.caption).textSelection(.enabled) }
                        }
                    }
                    Section("Đường dẫn đã kiểm tra") {
                        ForEach(report.checkedPaths, id: \.path) { entry in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.path).font(.caption.monospaced()).textSelection(.enabled)
                                Text(entry.visible ? "Đường dẫn truy cập được" : "Chưa truy cập được (errno \(entry.status))")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let text = entry.loadMessage { Text(text).font(.caption).textSelection(.enabled) }
                            }
                        }
                    }
                    if let roots = report.jailbreakRoots {
                        Section("Jailbreak root đã tìm") {
                            ForEach(roots, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                        }
                    }
                    if let notes = report.resolverNotes {
                        Section("Phân giải đường dẫn RootHide") {
                            ForEach(Array(notes.enumerated()), id: \.offset) { entry in
                                Text(entry.element).font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                    if let providers = report.providerChecks {
                        Section("Provider Dopamine") {
                            ForEach(providers, id: \.path) { entry in
                                VStack(alignment: .leading) {
                                    Text(entry.path).font(.caption.monospaced()).textSelection(.enabled)
                                    Text(entry.visible ? "Truy cập được" : "Chưa truy cập được (errno \(entry.status))").font(.caption)
                                }
                            }
                        }
                    }
                } else {
                    Section("Kết quả") { Text(store.message).font(.subheadline) }
                }
                if let trace = store.backendTrace {
                    Section("Giao tiếp backend") {
                        LabeledContent("Yêu cầu / bước", value: "\(trace.action) / \(trace.stage)")
                        if let count = trace.responseByteCount { LabeledContent("Byte phản hồi", value: String(count)) }
                        if let error = trace.decodingError { Text(error).font(.caption).textSelection(.enabled) }
                        Text("File JSON chia sẻ có phản hồi gốc và phiên bản ứng dụng để truy tìm lỗi định dạng.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Kiểm tra bằng terminal iOS") {
                    Text("Trong NewTerm, dùng su để vào phiên root do bạn quản lý, sau đó chạy lệnh bên dưới. Công cụ chỉ đọc 4 byte header tại base do provider trả về; không ghi kernel hoặc đọc game.")
                        .font(.footnote)
                    Text(terminalCommand).font(.caption.monospaced()).textSelection(.enabled)
                    Button(copied ? "Đã sao chép" : "Sao chép lệnh") {
                        UIPasteboard.general.string = terminalCommand
                        copied = true
                    }
                    Text("Đường dẫn này thay đổi khi cài lại ứng dụng. Sao chép lại từ bản đang cài. Chạy trực tiếp trong iSH không kiểm tra được kernel iOS.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Gửi kết quả") {
                    Button("Chuẩn bị file chẩn đoán") {
                        exportedFile = try? store.exportDiagnostics()
                    }
                    if let url = exportedFile { ShareLink("Chia sẻ file JSON", item: url) }
                }
            }.navigationTitle("Chẩn đoán kernel")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Đóng") { dismiss() } } }
        }
    }
}
