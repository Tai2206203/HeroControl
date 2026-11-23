import SwiftUI

@main
struct HeroControlApp: App {
    @StateObject private var store = ControlStore()
    var body: some Scene {
        WindowGroup { ContentView(store: store).preferredColorScheme(.dark) }
    }
}
