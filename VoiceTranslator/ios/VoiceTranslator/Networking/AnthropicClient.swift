import Foundation

final class AnthropicClient {
    private let apiKey: String
    private let model: String
    private let baseURL = URL(string: "https://api.anthropic.com/v1/messages")!

    init(apiKey: String, model: String = "claude-sonnet-4-20250514") {
        self.apiKey = apiKey
        self.model = model
    }

    struct StreamEvent {
        enum EventType {
            case textDelta(String)
            case messageComplete(String)
            case error(String)
        }
        let type: EventType
    }

    /// Streams a translation request, yielding text deltas as they arrive.
    func streamTranslation(
        systemPrompt: String,
        userMessage: String,
        conversationHistory: [(role: String, content: String)] = []
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var messages: [[String: String]] = conversationHistory.map {
                        ["role": $0.role, "content": $0.content]
                    }
                    messages.append(["role": "user", "content": userMessage])

                    let body: [String: Any] = [
                        "model": model,
                        "max_tokens": 1024,
                        "stream": true,
                        "system": systemPrompt,
                        "messages": messages
                    ]

                    var request = URLRequest(url: baseURL)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "content-type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: TranslationError.invalidResponse)
                        return
                    }

                    guard httpResponse.statusCode == 200 else {
                        var errorBody = ""
                        for try await line in bytes.lines { errorBody += line }
                        continuation.finish(throwing: TranslationError.apiError(
                            statusCode: httpResponse.statusCode, message: errorBody
                        ))
                        return
                    }

                    var fullText = ""

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonString = String(line.dropFirst(6))
                        guard jsonString != "[DONE]" else { break }

                        guard let data = jsonString.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = json["type"] as? String else { continue }

                        if type == "content_block_delta",
                           let delta = json["delta"] as? [String: Any],
                           let text = delta["text"] as? String {
                            fullText += text
                            continuation.yield(StreamEvent(type: .textDelta(text)))
                        } else if type == "message_stop" {
                            continuation.yield(StreamEvent(type: .messageComplete(fullText)))
                        } else if type == "error",
                                  let errorInfo = json["error"] as? [String: Any],
                                  let message = errorInfo["message"] as? String {
                            continuation.yield(StreamEvent(type: .error(message)))
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

enum TranslationError: LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case noAPIKey

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from API"
        case .apiError(let code, let msg): return "API error \(code): \(msg)"
        case .noAPIKey: return "No API key configured"
        }
    }
}
