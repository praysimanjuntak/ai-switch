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
                .frame(minWidth: 1120, minHeight: 640)
        }
        .defaultSize(width: 1180, height: 760)
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
