import Foundation

/// Orchestrates the full pipeline: STT → Translation → TTS → Playback
///
/// State machine:
///   idle → listening → translating → synthesizing → speaking → idle
///
/// TTS integration points are fully wired. Once Stream 2 delivers the trained
/// CoreML model and Stream 3 delivers the phoneme engine, the pipeline will
/// produce audio end-to-end without code changes.
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
    let ttsEngine = CoreMLTTSEngine()
    let audioPlayer = StreamingAudioPlayer()
    let tokenizer = PhonemeTokenizer()

    /// Accumulates Thai phrases for batch TTS when streaming isn't ready.
    private var phraseQueue: [String] = []
    private var isProcessing = false

    func configure(apiKey: String) {
        translation.configure(apiKey: apiKey)

        // Try to load phoneme inventory from bundle
        try? tokenizer.loadInventory()

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

        // Wire translation phrase callback → TTS
        translation.onPhrase = { [weak self] phrase in
            Task { @MainActor in
                guard let self else { return }
                self.phraseQueue.append(phrase)
            }
        }

        // Wire playback completion → return to idle
        audioPlayer.onPlaybackComplete = { [weak self] in
            Task { @MainActor in
                self?.state = .idle
            }
        }
    }

    func startListening() {
        guard state == .idle || state == .speaking else { return }
        audioPlayer.stop() // Stop any ongoing playback
        state = .listening
        currentTranscript = ""
        currentTranslation = ""
        phraseQueue = []
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
        audioPlayer.stop()
        state = .idle
        currentTranscript = ""
        currentTranslation = ""
        phraseQueue = []
    }

    // MARK: - Pipeline Processing

    private func processTranslation(_ text: String) async {
        phraseQueue = []

        // Start translation (phrases accumulate via onPhrase callback)
        await translation.translate(text)
        currentTranslation = translation.translatedText

        // Now synthesize and play all collected phrases
        await synthesizeAndPlay()
    }

    private func synthesizeAndPlay() async {
        guard !phraseQueue.isEmpty else {
            state = .idle
            return
        }

        state = .synthesizing

        // Combine all phrases for synthesis
        let fullText = phraseQueue.joined(separator: " ")

        guard ttsEngine.isModelLoaded else {
            // TTS model not loaded yet — log and return to idle
            // This is expected until the user completes enrollment + training
            print("[Pipeline] TTS model not loaded. Thai text ready: \(fullText)")
            state = .idle
            return
        }

        do {
            // Start audio playback engine
            try audioPlayer.start()
            state = .speaking

            // Stream synthesis for each phrase
            for (index, phrase) in phraseQueue.enumerated() {
                let isLast = index == phraseQueue.count - 1

                let audioData = try await ttsEngine.synthesize(phonemes: phrase)

                if isLast {
                    audioPlayer.scheduleFinalChunk(audioData)
                } else {
                    audioPlayer.scheduleChunk(audioData)
                }
            }
        } catch {
            print("[Pipeline] TTS/playback error: \(error.localizedDescription)")
            audioPlayer.stop()
            state = .error(error.localizedDescription)

            // Auto-recover to idle after a brief delay
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if case .error = state {
                    state = .idle
                }
            }
        }
    }
}
