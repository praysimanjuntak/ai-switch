import Foundation

enum CodexConfigEditor {
    static func ensureFileCredentialStore() throws {
        let manager = FileManager.default
        let codexHome = manager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        try manager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let config = codexHome.appendingPathComponent("config.toml")
        let backup = codexHome.appendingPathComponent("config.toml.ai-switch-backup")
        let existing = (try? String(contentsOf: config, encoding: .utf8)) ?? ""

        if manager.fileExists(atPath: config.path), !manager.fileExists(atPath: backup.path) {
            try manager.copyItem(at: config, to: backup)
        }

        let pattern = #"(?m)^\s*cli_auth_credentials_store\s*=.*$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(existing.startIndex..<existing.endIndex, in: existing)
        let updated: String
        if regex.firstMatch(in: existing, range: range) != nil {
            updated = regex.stringByReplacingMatches(
                in: existing,
                range: range,
                withTemplate: "cli_auth_credentials_store = \"file\""
            )
        } else {
            updated = "cli_auth_credentials_store = \"file\"\n" + existing
        }
        try updated.data(using: .utf8)?.write(to: config, options: .atomic)
    }
}
