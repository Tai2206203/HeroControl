import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var store: ControlStore
    @ObservedObject var overlay: OverlayController
    @Environment(\.scenePhase) private var scenePhase
    @State private var failed = false

    var body: some View {
        Color.clear.ignoresSafeArea()
            .overlay {
                if failed {
                    VStack(spacing: 16) {
                        Text("Không khởi động được nút nổi").font(.headline.bold())
                        ScrollView {
                            Text(store.persistenceError ?? overlay.failure ?? overlay.message)
                                .font(.system(.footnote, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button("DORO-CHEAT • Chạm để thử lại") { Task { await launch() } }
                            .font(.headline.bold()).buttonStyle(.borderedProminent)
                    }
                    .padding().frame(maxWidth: 600, maxHeight: 420)
                    .background(Color.white).foregroundColor(.black).cornerRadius(16).padding()
                }
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await launch()
            }
    }
    @MainActor private func launch() async {
        guard !overlay.busy else { return }
        failed = false
        store.reloadProfileIfChanged()
        guard let profile = store.prepareOverlayProfile() else { failed = true;return }
        await overlay.start(profile: profile)
        guard overlay.running else { failed = true;return }
#if !targetEnvironment(simulator)
        // The standalone window keeps running when this launcher goes home.
        let suspend = NSSelectorFromString("suspend")
        if UIApplication.shared.responds(to: suspend) { UIApplication.shared.perform(suspend) }
#endif
    }
}
