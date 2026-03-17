import Foundation

/// Orchestrates the full pipeline: STT → Translation → TTS → Playback
@MainActor
final class AudioPipeline: ObservableObject {
    enum PipelineState: Equatable {
        case idle
        case listening
        case translating
        case synthesizing
        case speaking
        case error(String)
    }

    @Published var state: PipelineState = .idle
    @Published var currentTranscript: String = ""
    @Published var currentTranslation: String = ""

    let stt = SpeechRecognitionService()
    let translation = TranslationService()
    // TTS engine will be added when Stream 3 (Gemini) delivers CoreMLTTSEngine

    private var isProcessing = false

    func configure(apiKey: String) {
        translation.configure(apiKey: apiKey)

        // Wire STT callbacks
        stt.onPartialResult = { [weak self] partial in
            Task { @MainActor in
                self?.currentTranscript = partial
            }
        }

        stt.onFinalResult = { [weak self] final in
            Task { @MainActor in
                guard let self else { return }
                self.currentTranscript = final
                self.state = .translating
                await self.processTranslation(final)
            }
        }

        // Wire translation phrase callback (will feed to TTS)
        translation.onPhrase = { [weak self] phrase in
            Task { @MainActor in
                guard let self else { return }
                self.state = .synthesizing
                // TODO: Feed phrase to CoreMLTTSEngine when available
                // For now, log it
                print("[Pipeline] Thai phrase ready for TTS: \(phrase)")
            }
        }
    }

    func startListening() {
        guard state == .idle || state == .speaking else { return }
        state = .listening
        currentTranscript = ""
        currentTranslation = ""
        stt.startListening()
    }

    func stopListening() {
        stt.stopListening()
        if currentTranscript.isEmpty {
            state = .idle
        }
    }

    func reset() {
        stt.stopListening()
        state = .idle
        currentTranscript = ""
        currentTranslation = ""
    }

    private func processTranslation(_ text: String) async {
        await translation.translate(text)
        currentTranslation = translation.translatedText

        // After TTS plays, return to idle
        // TODO: Wait for actual TTS playback completion
        state = .idle
    }
}
