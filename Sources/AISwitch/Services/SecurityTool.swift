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
    /// write, for example while it is locked, or when the item is too large for
    /// `security -i`; callers fall back to an owner-only file in both cases. The
    /// secret is never passed as a process argument, where `ps` could read it.
    static func write(_ data: Data, service: String, account: String) async throws -> Bool {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        var line = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\"\n"
        if line.utf8.count > interactiveLineLimit,
           let ascii = String(data: data, encoding: .utf8),
           ascii.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A)
               || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2B || $0 == 0x2D || $0 == 0x2F
               || $0 == 0x3A || $0 == 0x3D || $0 == 0x5F }) {
            // Pure base64 / keyring-prefixed ASCII takes half the line length with `-w`.
            line = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -w \"\(ascii)\"\n"
        }
        guard line.utf8.count <= interactiveLineLimit else { return false }
        let result = try await CommandRunner.run(
            executable: executable, arguments: ["-i"], input: Data(line.utf8), timeout: 10
        )
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
