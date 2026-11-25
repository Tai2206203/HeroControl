import SwiftUI

@main
struct HeroControlApp: App {
    @StateObject private var store = ControlStore()
    @StateObject private var overlay = OverlayController()
    var body: some Scene {
        WindowGroup { ContentView(store: store, overlay: overlay) }
    }
}
