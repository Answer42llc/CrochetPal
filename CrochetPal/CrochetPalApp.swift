//
//  CrochetPalApp.swift
//  CrochetPal
//
//  Created by lw on 4/8/26.
//

import Combine
import SwiftUI

@MainActor
private final class AppBootstrapper: ObservableObject {
    let container: AppContainer?

    init() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            self.container = nil
        } else {
            self.container = AppContainer.make()
        }
    }
}

@main
struct CrochetPalApp: App {
    @StateObject private var bootstrapper = AppBootstrapper()

    var body: some Scene {
        WindowGroup {
            if let container = bootstrapper.container {
                ContentView()
                    .environmentObject(container)
            } else {
                Text("CrochetPal Test Host")
            }
        }
    }
}
