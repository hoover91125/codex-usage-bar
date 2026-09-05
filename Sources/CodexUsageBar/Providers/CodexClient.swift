import Foundation

enum CodexUsageClient: UsageProviderClient {
    static let provider: UsageProvider = .codex

    static func isInstalled() -> Bool {
        findCodexExecutable() != nil
    }

    static func fetch() throws -> ProviderSnapshot {
        guard let executable = findCodexExecutable() else {
            throw UsageClientError.codexNotFound
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw UsageClientError.launchFailed(error.localizedDescription)
        }

        let timedOut = LockedFlag()
        let timeout = DispatchWorkItem {
            if process.isRunning {
                timedOut.value = true
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: timeout)

        let initialize: [String: Any] = [
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "codex-usage-bar",
                    "title": "Codex Usage Bar",
                    "version": "1.0.0"
                ],
                "capabilities": ["experimentalApi": true]
            ]
        ]
        let request: [String: Any] = [
            "id": 2,
            "method": "account/rateLimits/read",
            "params": NSNull()
        ]

        do {
            let payload = try line(for: initialize) + line(for: request)
            try input.fileHandleForWriting.write(contentsOf: payload)
        } catch {
            if process.isRunning { process.terminate() }
            timeout.cancel()
            throw UsageClientError.launchFailed(error.localizedDescription)
        }

        var responseData = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            responseData.append(chunk)
            if containsResponse(id: 2, in: responseData) { break }
        }
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        timeout.cancel()

        if timedOut.value && !containsResponse(id: 2, in: responseData) {
            throw UsageClientError.timedOut
        }

        return try parseResponse(responseData)
    }

    private static func containsResponse(id: Int, in data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.split(whereSeparator: \.isNewline).contains { line in
            guard let lineData = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                return false
            }
            return (json["id"] as? NSNumber)?.intValue == id
        }
    }

    private static func line(for object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return data
    }

    private static func parseResponse(_ data: Data) throws -> ProviderSnapshot {
        guard let text = String(data: data, encoding: .utf8) else {
            throw UsageClientError.invalidResponse
        }

        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (json["id"] as? NSNumber)?.intValue == 2 else {
                continue
            }

            if let error = json["error"] as? [String: Any] {
                throw UsageClientError.server(error["message"] as? String ?? "Unknown error")
            }

            guard let result = json["result"] as? [String: Any],
                  let limits = preferredLimits(from: result) else {
                throw UsageClientError.invalidResponse
            }

            let credits = limits["credits"] as? [String: Any]
            let resets = result["rateLimitResetCredits"] as? [String: Any]

            return ProviderSnapshot(
                provider: .codex,
                primary: parseWindow(limits["primary"]),
                secondary: parseWindow(limits["secondary"]),
                extras: [],
                plan: limits["planType"] as? String,
                credits: CreditInfo(
                    balance: credits?["balance"] as? String,
                    unlimited: credits?["unlimited"] as? Bool ?? false,
                    resetCount: (resets?["availableCount"] as? NSNumber)?.intValue ?? 0
                ),
                fetchedAt: Date()
            )
        }

        throw UsageClientError.invalidResponse
    }

    private static func preferredLimits(from result: [String: Any]) -> [String: Any]? {
        if let buckets = result["rateLimitsByLimitId"] as? [String: Any],
           let codex = buckets["codex"] as? [String: Any] {
            return codex
        }
        return result["rateLimits"] as? [String: Any]
    }

    private static func parseWindow(_ value: Any?) -> RateWindow? {
        guard let object = value as? [String: Any],
              let used = (object["usedPercent"] as? NSNumber)?.intValue else {
            return nil
        }
        let duration = (object["windowDurationMins"] as? NSNumber)?.intValue
        let resetTimestamp = (object["resetsAt"] as? NSNumber)?.doubleValue
        return RateWindow(
            usedPercent: used,
            durationMinutes: duration,
            resetsAt: resetTimestamp.map(Date.init(timeIntervalSince1970:))
        )
    }

    private static func findCodexExecutable() -> URL? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        return candidates
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map(URL.init(fileURLWithPath:))
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
