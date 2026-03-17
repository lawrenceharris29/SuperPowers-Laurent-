import Foundation

@MainActor
final class TranslationService: ObservableObject {
    @Published var translatedText: String = ""
    @Published var isTranslating: Bool = false

    private var client: AnthropicClient?
    private var conversationHistory: [(role: String, content: String)] = []
    private let maxHistoryPairs = 5

    // Callback: fires for each streamed phrase (complete enough to send to TTS)
    var onPhrase: ((String) -> Void)?

    private let systemPrompt = """
    You are a real-time voice translator. Translate the following spoken English \
    into natural spoken Thai (ภาษาพูด, not formal written Thai).

    Rules:
    - Use colloquial register appropriate for everyday conversation
    - Preserve the speaker's tone and intent (casual, urgent, polite, etc.)
    - Use ครับ for male speaker, ค่ะ for female speaker (default to ครับ)
    - Do NOT add explanations, notes, or alternatives
    - Output ONLY the Thai translation in Thai script
    - Do NOT include romanization or pronunciation guides
    - For greetings, use natural Thai equivalents (e.g., "Hi" → "สวัสดีครับ")
    - Translate idioms to Thai cultural equivalents, not literally
    """

    func configure(apiKey: String) {
        client = AnthropicClient(apiKey: apiKey)
    }

    func translate(_ englishText: String) async {
        guard let client else { return }

        isTranslating = true
        translatedText = ""

        var phraseBuffer = ""

        do {
            let stream = client.streamTranslation(
                systemPrompt: systemPrompt,
                userMessage: englishText,
                conversationHistory: conversationHistory
            )

            for try await event in stream {
                switch event.type {
                case .textDelta(let delta):
                    translatedText += delta
                    phraseBuffer += delta

                    // Emit complete phrases for TTS
                    // Thai uses spaces between phrases/clauses, so split on spaces
                    // Also split on Thai punctuation
                    if let range = phraseBuffer.rangeOfCharacter(from: Self.phraseBoundaries, options: .backwards) {
                        let completePhrase = String(phraseBuffer[phraseBuffer.startIndex...range.lowerBound])
                        let remainder = String(phraseBuffer[range.upperBound...])

                        if !completePhrase.trimmingCharacters(in: .whitespaces).isEmpty {
                            onPhrase?(completePhrase.trimmingCharacters(in: .whitespaces))
                        }
                        phraseBuffer = remainder
                    }

                case .messageComplete:
                    // Flush remaining buffer
                    let remaining = phraseBuffer.trimmingCharacters(in: .whitespaces)
                    if !remaining.isEmpty {
                        onPhrase?(remaining)
                    }
                    phraseBuffer = ""

                    // Update conversation history
                    appendToHistory(role: "user", content: englishText)
                    appendToHistory(role: "assistant", content: translatedText)

                case .error(let message):
                    print("[Translation] Stream error: \(message)")
                }
            }
        } catch {
            print("[Translation] Error: \(error.localizedDescription)")
        }

        isTranslating = false
    }

    func clearHistory() {
        conversationHistory.removeAll()
    }

    private func appendToHistory(role: String, content: String) {
        conversationHistory.append((role: role, content: content))
        // Keep only last N pairs
        let maxEntries = maxHistoryPairs * 2
        if conversationHistory.count > maxEntries {
            conversationHistory = Array(conversationHistory.suffix(maxEntries))
        }
    }

    // Characters that indicate a phrase boundary in Thai text
    private static let phraseBoundaries = CharacterSet(charactersIn: " \u{0E2F}\u{0E46},.!?")
}
