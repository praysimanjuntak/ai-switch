import Foundation

/// Puts `aiswitch` on the PATH: a link in `~/.local/bin`, the folder Claude
/// Code's own installer uses, to this app's executable. When Homebrew links
/// the command itself, an AI Switch link in `~/.local/bin` is removed instead,
/// since that folder usually comes first on the PATH and would shadow it. An
/// app running from a disk image or a translocated copy, whose path won't
/// last, changes nothing. A file or link of another program's under that name
/// is never replaced; a link to another copy of AI Switch is moved to this one.
enum CommandLineTool {
    static let homebrewLinks = ["/opt/homebrew/bin", "/usr/local/bin"].map {
        URL(fileURLWithPath: $0).appendingPathComponent(AgentCLI.name)
    }

    /// Returns the link when it points at `executable` afterwards.
    @discardableResult
    static func install(executable: URL, home: URL, linkedElsewhere: [URL] = homebrewLinks) -> URL? {
        let target = executable.path
        guard isAppExecutable(target), !target.hasPrefix("/Volumes/"), !target.contains("/AppTranslocation/") else { return nil }
        let manager = FileManager.default
        let link = home.appendingPathComponent(".local/bin", isDirectory: true).appendingPathComponent(AgentCLI.name)
        let destination = try? manager.destinationOfSymbolicLink(atPath: link.path)
        if linkedElsewhere.contains(where: { (try? manager.destinationOfSymbolicLink(atPath: $0.path)).map(isAppExecutable) == true }) {
            if let destination, isAppExecutable(destination) { try? manager.removeItem(at: link) }
            return nil
        }
        if let destination {
            if destination == target { return link }
            guard isAppExecutable(destination), (try? manager.removeItem(at: link)) != nil else { return nil }
        } else if manager.fileExists(atPath: link.path) {
            return nil
        }
        do {
            try manager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.createSymbolicLink(atPath: link.path, withDestinationPath: target)
            return link
        } catch {
            return nil
        }
    }

    private static func isAppExecutable(_ path: String) -> Bool {
        path.hasSuffix(".app/Contents/MacOS/AISwitch")
    }
}
