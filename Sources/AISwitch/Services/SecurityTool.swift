import Foundation

/// Generic-password items in the login Keychain, accessed through `/usr/bin/security`
/// like the CLIs that own them do. Items created with the `security` tool are
/// readable by it without the per-app authorization dialogs the Security
/// framework would trigger for this app.
enum SecurityTool {
    private static let executable = URL(fileURLWithPath: "/usr/bin/security")
    private static let absentExitCodes: Set<Int32> = [44, 36] // Item not found, keychain unavailable.
    /// `security -i` rejects longer command lines; Claude Code uses the same limit.
    private static let interactiveLineLimit = 4032

    /// The item's secret, or nil when no such item exists.
    static func read(service: String, account: String?) async throws -> Data? {
        var arguments = ["find-generic-password", "-w", "-s", service]
        if let account { arguments += ["-a", account] }
        let result = try await CommandRunner.run(executable: executable, arguments: arguments, timeout: 10)
        if result.exitCode == 0 {
            return result.output.isEmpty ? nil : Data(result.output.utf8)
        }
        guard absentExitCodes.contains(result.exitCode) else {
            throw AISwitchError.commandFailed("Keychain read failed: \(result.output)")
        }
        return nil
    }

    /// Creates or updates the item. Returns false when the Keychain rejected the
    /// write, for example while it is locked.
    static func write(_ data: Data, service: String, account: String) async throws -> Bool {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let line = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\"\n"
        let result: CommandResult
        if line.utf8.count <= interactiveLineLimit {
            // Keep the secret out of process arguments, where `ps` could read it.
            result = try await CommandRunner.run(
                executable: executable, arguments: ["-i"], input: Data(line.utf8), timeout: 10
            )
        } else {
            result = try await CommandRunner.run(
                executable: executable,
                arguments: ["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex],
                timeout: 10
            )
        }
        return result.exitCode == 0
    }

    static func delete(service: String, account: String) async {
        _ = try? await CommandRunner.run(
            executable: executable,
            arguments: ["delete-generic-password", "-a", account, "-s", service],
            timeout: 10
        )
    }
}
