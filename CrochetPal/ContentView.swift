//
//  ContentView.swift
//  CrochetPal
//
//  Created by lw on 4/8/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        NavigationStack {
            ProjectListView()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppContainer.make())
}
