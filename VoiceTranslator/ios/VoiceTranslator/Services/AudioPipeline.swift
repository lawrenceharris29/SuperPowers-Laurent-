import Foundation

/// Orchestrates the full pipeline: STT → Translation → TTS → Playback
///
/// State machine:
///   idle → listening → translating → synthesizing → speaking → idle
///
/// TTS integration is fully wired using:
///   - PhonemeTokenizer (Gemini's thai_phonemes.json vocab)
///   - CoreMLTTSEngine (VITS model, phoneme IDs + durations → Float32 PCM)
///   - StreamingAudioPlayer (schedules [Float] chunks for gapless playback)
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
    let audioPlayer = StreamingAudioPlayer(sampleRate: 22050)
    let tokenizer = PhonemeTokenizer()

    /// Accumulates Thai phrases for TTS after translation completes.
    private var phraseQueue: [String] = []

    func configure(apiKey: String) {
        translation.configure(apiKey: apiKey)

        // Load phoneme inventory from bundle
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

        // Wire translation phrase callback → accumulate for TTS
        translation.onPhrase = { [weak self] phrase in
            Task { @MainActor in
                self?.phraseQueue.append(phrase)
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
        audioPlayer.stop()
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

        // Translation streams phrases via onPhrase callback
        await translation.translate(text)
        currentTranslation = translation.translatedText

        await synthesizeAndPlay()
    }

    private func synthesizeAndPlay() async {
        guard !phraseQueue.isEmpty else {
            state = .idle
            return
        }

        state = .synthesizing

        let fullText = phraseQueue.joined(separator: " ")

        guard ttsEngine.isModelLoaded else {
            // Model not loaded — expected until enrollment + training completes
            print("[Pipeline] TTS model not loaded. Thai text: \(fullText)")
            state = .idle
            return
        }

        guard tokenizer.isLoaded else {
            print("[Pipeline] Phoneme tokenizer not loaded.")
            state = .idle
            return
        }

        do {
            try audioPlayer.start()
            state = .speaking

            for (index, phrase) in phraseQueue.enumerated() {
                let isLast = index == phraseQueue.count - 1

                // Tokenize the Thai IPA phrase
                let tokenIDs = try tokenizer.tokenize(phrase)

                // Default durations (200ms per token) — ProsodyModel will
                // provide real durations once the server-side pipeline runs
                let durations = [Int32](repeating: 200, count: tokenIDs.count)

                // Synthesize: phoneme IDs → Float32 PCM
                let pcmSamples = try await ttsEngine.synthesize(
                    phonemeIDs: tokenIDs,
                    durations: durations
                )

                // Normalize audio before playback
                var normalizedSamples = pcmSamples
                AudioUtilities.normalize(pcmData: &normalizedSamples)

                if isLast {
                    audioPlayer.scheduleFinalChunk(normalizedSamples)
                } else {
                    audioPlayer.scheduleChunk(normalizedSamples)
                }
            }
        } catch {
            print("[Pipeline] TTS/playback error: \(error.localizedDescription)")
            audioPlayer.stop()
            state = .error(error.localizedDescription)

            // Auto-recover to idle
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if case .error = state {
                    state = .idle
                }
            }
        }
    }
}
