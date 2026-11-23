import SwiftUI

@main
struct HeroControlApp: App {
    @StateObject private var store = ControlStore()
    @StateObject private var overlay = OverlayController()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ContentView(store: store, overlay: overlay).preferredColorScheme(.dark)
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    store.reloadProfileIfChanged()
                    if let profile = store.prepareOverlayProfile() { await overlay.start(profile: profile) }
                    while !Task.isCancelled {
                        await overlay.refresh()
                        store.reloadProfileIfChanged()
                        do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                        catch { break }
                    }
                }
        }
    }
}
