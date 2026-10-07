import AppKit
import SwiftUI

@main
struct AISwitchApp: App {
    @StateObject private var store = AccountStore()

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.light)
                .frame(minWidth: 1000, minHeight: 560)
        }
        .defaultSize(width: 1120, height: 720)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(store)
                .preferredColorScheme(.light)
        } label: {
            Label("AI Switch", systemImage: "arrow.triangle.2.circlepath")
        }
        .menuBarExtraStyle(.window)
    }
}
