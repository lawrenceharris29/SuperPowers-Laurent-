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

    /// Speaker gender affects politeness particles (ครับ vs ค่ะ)
    var speakerGender: SpeakerGender = .male

    enum SpeakerGender: String {
        case male, female
        var particle: String { self == .male ? "ครับ" : "ค่ะ" }
        var particleAlt: String { self == .male ? "ครับ" : "คะ" }
    }

    private var systemPrompt: String {
        """
        You are a real-time voice translator. Translate spoken English into \
        natural spoken Thai (ภาษาพูด, not formal written Thai).

        CRITICAL RULES:
        1. Output ONLY Thai script. No romanization, no explanations, no alternatives.
        2. Use colloquial register for everyday conversation.
        3. Preserve the speaker's tone and intent (casual, urgent, polite, humorous).
        4. Use \(speakerGender.particle) for polite particles (speaker is \(speakerGender.rawValue)).
        5. Use \(speakerGender.particleAlt) for question particles.
        6. Translate idioms to Thai cultural equivalents, not literally.
        7. For greetings, use natural Thai: "Hi" → "สวัสดี\(speakerGender.particle)"
        8. Keep translations concise — prefer short spoken forms over verbose written forms.

        TONAL ACCURACY:
        - Thai is a tonal language with 5 tones. Choose words carefully to preserve \
          meaning. When multiple Thai words could translate an English word, prefer the \
          one most commonly used in spoken conversation.
        - Maintain natural Thai prosody: avoid unnatural word order that sounds translated.

        PHRASE STRUCTURE:
        - Use spaces between clauses to enable incremental text-to-speech.
        - Place natural pause points (spaces) where a Thai speaker would pause.
        - Keep each clause short enough for fluid speech synthesis (3-8 syllables ideal).
        """
    }

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
