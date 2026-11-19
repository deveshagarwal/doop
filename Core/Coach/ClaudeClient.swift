import Foundation

public enum CoachError: Error, LocalizedError {
    case noKey, http(Int, String), refused

    public var errorDescription: String? {
        switch self {
        case .noKey: return "Add your Anthropic API key in Settings to use the coach."
        case .http(let code, let body): return "Claude API error \(code): \(body)"
        case .refused: return "Claude declined to answer that one."
        }
    }
}

/// Streams a reply from the Claude Messages API over raw HTTP (there is no official Swift SDK).
/// Server-side refusal fallbacks are on, so a declined request is retried on another model in the same call.
public struct ClaudeClient: Sendable {
    public static let model = "claude-opus-5"
    public static let keychainService = "baseline.anthropic"
    public let apiKey: String

    public init(apiKey: String) { self.apiKey = apiKey }

    public static func storedKey() -> String? {
        Keychain.load(service: keychainService, account: "api-key").flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func storeKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(service: keychainService, account: "api-key")
        } else {
            Keychain.save(Data(trimmed.utf8), service: keychainService, account: "api-key")
        }
    }

    /// Yields text deltas as they arrive.
    public func stream(system: String, messages: [ChatMessage], maxTokens: Int = 8000) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 300
                    req.setValue("application/json", forHTTPHeaderField: "content-type")
                    req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                    let body: [String: Any] = [
                        "model": Self.model,
                        "max_tokens": maxTokens,
                        "stream": true,
                        "fallbacks": "default",
                        "output_config": ["effort": "medium"],
                        // Stable system prompt first so it caches across turns.
                        "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
                        "messages": messages.map { ["role": $0.role.rawValue, "content": $0.text] },
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var text = ""
                        for try await line in bytes.lines { text += line; if text.count > 500 { break } }
                        throw CoachError.http(status, String(text.prefix(300)))
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: "),
                              let json = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any]
                        else { continue }
                        switch json["type"] as? String {
                        case "content_block_delta":
                            if let delta = json["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                               let text = delta["text"] as? String {
                                continuation.yield(text)
                            }
                        case "message_delta":
                            if (json["delta"] as? [String: Any])?["stop_reason"] as? String == "refusal" {
                                throw CoachError.refused
                            }
                        case "error":
                            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? "stream error"
                            throw CoachError.http(0, msg)
                        default: break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
