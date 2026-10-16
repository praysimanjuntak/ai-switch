import AppKit
import SwiftUI

/// One executable for both: the app, or the `aiswitch` command when started
/// under that name or with a command.
@main
enum AISwitchMain {
    static func main() {
        if let command = AgentCLI(arguments: CommandLine.arguments) {
            exit(command.run())
        }
        if let executable = Bundle.main.executableURL {
            CommandLineTool.install(executable: executable, home: FileManager.default.homeDirectoryForCurrentUser)
        }
        MainActor.assumeIsolated { AISwitchApp.main() }
    }
}

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
