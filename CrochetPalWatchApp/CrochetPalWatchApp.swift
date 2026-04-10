import SwiftUI

@main
struct CrochetPalWatchApp: App {
    @StateObject private var store = WatchCompanionStore.make()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(store)
        }
    }
}
