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
                .frame(minWidth: 940, minHeight: 600)
        }
        .defaultSize(width: 1080, height: 740)
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
