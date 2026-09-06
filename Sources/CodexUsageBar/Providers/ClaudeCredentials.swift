import Foundation
import CryptoKit
import LocalAuthentication
import Security

/// The decoded `claudeAiOauth` blob. Never log or expose `accessToken`
/// outside of the single HTTPS request that uses it. `refreshToken` is
/// intentionally not kept around: this app never performs the OAuth refresh,
/// so there's no reason to hold a second live secret in memory.
struct ClaudeCredentials {
    let accessToken: String
    let expiresAt: Date
    let subscriptionType: String?

    var isExpired: Bool { expiresAt < Date() }
}

enum ClaudeCredentialStore {
    /// True if a credential entry can be located. Deliberately does not use
    /// `security -w` here: that flag extracts the secret and is what triggers
    /// the macOS authorization dialog, which this call must never do since
    /// Phase 3 calls it from UI code to decide whether to show a section.
    static func isAvailable() -> Bool {
        for service in candidateServiceNames() {
            if keychainEntryExists(account: account(), service: service) { return true }
        }
        return FileManager.default.fileExists(atPath: credentialsFilePath())
    }

    /// The Security framework query shared by the two Keychain readers below.
    /// The `LAContext` with `interactionNotAllowed` is what makes both silent:
    /// an item this app is not on the ACL of comes back as
    /// `errSecInteractionNotAllowed` instead of putting an authorization
    /// dialog on screen behind the user's back. (The older
    /// `kSecUseAuthenticationUIFail` spelling does the same thing and is what
    /// CodexBar uses, but it is deprecated in favor of exactly this.)
    private static func keychainQuery(account: String, service: String, returnData: Bool) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            returnData ? kSecReturnData as String : kSecReturnAttributes as String: true,
            kSecUseAuthenticationContext as String: context
        ]
    }

    /// Reads the item through the Security framework. This is the *fallback*,
    /// not the preferred path, which is the opposite of what it looks like:
    /// measured on this machine the `security` subprocess below returns the
    /// same 566 bytes in 10–20 ms every time, while this call took 5.5–6.7 s
    /// on its first uses (it goes through SecurityAgent to evaluate the item's
    /// ACL) before settling to ~9 ms once cached. `/usr/bin/security` is
    /// Apple-signed and already trusted for this item, so it skips all of
    /// that. What this call is good for is the case the subprocess can't
    /// cover — `/usr/bin/security` missing or refusing — so it runs after.
    private static func readKeychainDirect(account: String, service: String) -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            keychainQuery(account: account, service: service, returnData: true) as CFDictionary,
            &result
        )
        guard status == errSecSuccess, let data = result as? Data, !data.isEmpty else { return nil }
        return data
    }

    /// Existence check that returns attributes rather than the secret, so
    /// there is no ACL decision to make and it resolves in a few milliseconds
    /// — genuinely better than spawning `security` for this, unlike the read
    /// above, which is why this one does go first.
    private static func keychainEntryExistsDirect(account: String, service: String) -> Bool {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            keychainQuery(account: account, service: service, returnData: false) as CFDictionary,
            &result
        )
        return status == errSecSuccess
    }

    static func load() throws -> ClaudeCredentials {
        guard let data = try locate() else {
            throw UsageClientError.claudeCredentialsNotFound
        }
        return try parse(data)
    }

    private static func locate() throws -> Data? {
        let account = account()
        let services = candidateServiceNames()
        for service in services {
            if let data = readKeychain(account: account, service: service) {
                return data
            }
        }
        for service in services {
            if let data = readKeychainDirect(account: account, service: service) {
                return data
            }
        }
        return readCredentialsFile()
    }

    private static func account() -> String {
        let candidate = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        let pattern = "^[a-zA-Z0-9._-]+$"
        if candidate.range(of: pattern, options: .regularExpression) != nil {
            return candidate
        }
        return "claude-code-user"
    }

    private static func candidateServiceNames() -> [String] {
        let base = "Claude Code-credentials"
        guard let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !configDir.isEmpty else {
            return [base]
        }
        let normalized = configDir.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hash8 = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        return [base, "\(base)-\(hash8)"]
    }

    /// Runs `security find-generic-password` without `-w`: it exits 0 when the
    /// item exists and prints only attributes (no secret), so this never pops
    /// the authorization dialog that reading the password would.
    private static func keychainEntryExists(account: String, service: String) -> Bool {
        if keychainEntryExistsDirect(account: account, service: service) { return true }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", account, "-s", service]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return false
        }
        // Drain both pipes before waiting so `security` can't block on a full
        // pipe buffer; the attribute dump is small but this keeps it safe.
        _ = output.fileHandleForReading.readDataToEndOfFile()
        _ = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func readKeychain(account: String, service: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", account, "-w", "-s", service]

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        _ = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        // `security -w` appends a trailing newline; trim it before treating this as JSON.
        var trimmed = data
        while let last = trimmed.last, last == 0x0A || last == 0x0D {
            trimmed.removeLast()
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func credentialsFilePath() -> String {
        let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() + "/.claude")
        return configDir + "/.credentials.json"
    }

    private static func readCredentialsFile() -> Data? {
        FileManager.default.contents(atPath: credentialsFilePath())
    }

    private static func parse(_ data: Data) throws -> ClaudeCredentials {
        // Unusable and absent credentials share the same remedy (sign in with
        // Claude Code), so a malformed blob gets the same error as not found.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              let expiresAtMillis = (oauth["expiresAt"] as? NSNumber)?.doubleValue else {
            throw UsageClientError.claudeCredentialsNotFound
        }
        return ClaudeCredentials(
            accessToken: accessToken,
            expiresAt: Date(timeIntervalSince1970: expiresAtMillis / 1000),
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }
}
