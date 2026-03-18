import Foundation
import os.log

/// Orchestrates the full pipeline: STT → Translation → TTS → Playback
///
/// State machine:
///   idle → listening → translating → synthesizing → speaking → idle
///
/// Latency optimizations:
///   1. Speculative TTS: begins synthesizing phrases as they stream from Claude,
///      rather than waiting for the full translation to complete.
///   2. Pre-warming: CoreML model and audio engine are warmed up during STT
///      so they're ready when translation arrives.
///   3. Concurrent stages: TTS synthesis and audio playback overlap — chunks
///      play while the next chunk is being synthesized.
///   4. Latency tracking: measures and logs time for each pipeline stage.
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

    /// Accumulates Thai phrases for TTS.
    private var phraseQueue: [String] = []

    /// When true, synthesize phrases as they arrive from Claude (speculative TTS).
    private var speculativeTTSEnabled = true

    /// Track whether we're already processing speculative TTS phrases.
    private var speculativeTTSTask: Task<Void, Never>?

    /// Latency tracking
    private let logger = Logger(subsystem: "com.voicetranslator", category: "Pipeline")
    private var pipelineStartTime: CFAbsoluteTime = 0
    private var translationStartTime: CFAbsoluteTime = 0
    private var firstPhraseTime: CFAbsoluteTime = 0
    private var ttsStartTime: CFAbsoluteTime = 0

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
                self.translationStartTime = CFAbsoluteTimeGetCurrent()
                await self.processTranslation(final)
            }
        }

        // Wire translation phrase callback → speculative TTS
        translation.onPhrase = { [weak self] phrase in
            Task { @MainActor in
                guard let self else { return }

                if self.firstPhraseTime == 0 {
                    self.firstPhraseTime = CFAbsoluteTimeGetCurrent()
                    let latency = self.firstPhraseTime - self.translationStartTime
                    self.logger.info("First phrase latency: \(latency, format: .fixed(precision: 3))s")
                }

                self.phraseQueue.append(phrase)

                // Speculative TTS: start synthesizing immediately
                if self.speculativeTTSEnabled && self.ttsEngine.isModelLoaded {
                    self.startSpeculativeTTS()
                }
            }
        }

        // Wire playback completion → return to idle
        audioPlayer.onPlaybackComplete = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let totalLatency = CFAbsoluteTimeGetCurrent() - self.pipelineStartTime
                self.logger.info("Total pipeline round-trip: \(totalLatency, format: .fixed(precision: 3))s")
                self.state = .idle
            }
        }
    }

    /// Set speaker gender for translation politeness particles.
    func setSpeakerGender(_ gender: TranslationService.SpeakerGender) {
        translation.speakerGender = gender
    }

    func startListening() {
        guard state == .idle || state == .speaking else { return }
        audioPlayer.stop()
        speculativeTTSTask?.cancel()
        speculativeTTSTask = nil
        state = .listening
        currentTranscript = ""
        currentTranslation = ""
        phraseQueue = []
        pipelineStartTime = CFAbsoluteTimeGetCurrent()
        firstPhraseTime = 0

        // Pre-warm: prepare the audio engine while user speaks
        prewarmAudioEngine()

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
        speculativeTTSTask?.cancel()
        speculativeTTSTask = nil
        state = .idle
        currentTranscript = ""
        currentTranslation = ""
        phraseQueue = []
    }

    // MARK: - Pre-warming

    /// Pre-warms the audio engine during STT so playback starts instantly.
    private func prewarmAudioEngine() {
        do {
            try audioPlayer.start()
        } catch {
            logger.warning("Audio engine pre-warm failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Pipeline Processing

    private func processTranslation(_ text: String) async {
        phraseQueue = []

        // Translation streams phrases via onPhrase callback
        await translation.translate(text)
        currentTranslation = translation.translatedText

        let translationLatency = CFAbsoluteTimeGetCurrent() - translationStartTime
        logger.info("Full translation latency: \(translationLatency, format: .fixed(precision: 3))s")

        // If speculative TTS already handled everything, we're done.
        // Otherwise, fall back to sequential synthesis.
        if speculativeTTSTask == nil {
            await synthesizeAndPlay()
        } else {
            // Wait for speculative TTS to finish remaining phrases
            speculativeTTSTask?.cancel()
            speculativeTTSTask = nil
            await synthesizeRemaining()
        }
    }

    // MARK: - Speculative TTS

    /// Starts synthesizing phrases concurrently with translation streaming.
    /// Each phrase is synthesized and scheduled for playback as it arrives.
    private var speculativeIndex = 0

    private func startSpeculativeTTS() {
        guard speculativeTTSTask == nil else { return }
        speculativeIndex = 0
        ttsStartTime = CFAbsoluteTimeGetCurrent()

        speculativeTTSTask = Task { [weak self] in
            guard let self else { return }

            do {
                try self.audioPlayer.start()
            } catch {
                self.logger.error("Failed to start audio player for speculative TTS: \(error.localizedDescription)")
                return
            }

            await MainActor.run { self.state = .speaking }

            while !Task.isCancelled {
                let currentQueue = await MainActor.run { self.phraseQueue }
                let idx = await MainActor.run { self.speculativeIndex }

                if idx < currentQueue.count {
                    let phrase = currentQueue[idx]
                    await MainActor.run { self.speculativeIndex += 1 }

                    await self.synthesizePhrase(phrase, isFinal: false)
                } else {
                    // Check if translation is still streaming
                    let stillTranslating = await MainActor.run { self.translation.isTranslating }
                    if !stillTranslating {
                        // All phrases received, schedule the last one as final
                        break
                    }
                    // Wait briefly for more phrases
                    try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
                }
            }
        }
    }

    /// Synthesizes any phrases that speculative TTS hasn't reached yet.
    private func synthesizeRemaining() async {
        let remaining = Array(phraseQueue.dropFirst(speculativeIndex))
        guard !remaining.isEmpty else {
            // Schedule a silent final chunk to trigger completion callback
            audioPlayer.scheduleFinalChunk([Float](repeating: 0, count: 1))
            return
        }

        for (i, phrase) in remaining.enumerated() {
            let isFinal = i == remaining.count - 1
            await synthesizePhrase(phrase, isFinal: isFinal)
        }
    }

    /// Synthesizes a single phrase and schedules it for playback.
    private func synthesizePhrase(_ phrase: String, isFinal: Bool) async {
        guard ttsEngine.isModelLoaded, tokenizer.isLoaded else { return }

        do {
            let tokenIDs = try tokenizer.tokenize(phrase)
            let durations = [Int32](repeating: 200, count: tokenIDs.count)

            let pcmSamples = try await ttsEngine.synthesize(
                phonemeIDs: tokenIDs,
                durations: durations
            )

            var normalizedSamples = pcmSamples
            AudioUtilities.normalize(pcmData: &normalizedSamples)

            if isFinal {
                audioPlayer.scheduleFinalChunk(normalizedSamples)
            } else {
                audioPlayer.scheduleChunk(normalizedSamples)
            }
        } catch {
            logger.error("Speculative TTS failed for phrase: \(error.localizedDescription)")
        }
    }

    // MARK: - Sequential Fallback

    private func synthesizeAndPlay() async {
        guard !phraseQueue.isEmpty else {
            state = .idle
            return
        }

        state = .synthesizing
        ttsStartTime = CFAbsoluteTimeGetCurrent()

        let fullText = phraseQueue.joined(separator: " ")

        guard ttsEngine.isModelLoaded else {
            logger.notice("TTS model not loaded. Thai text: \(fullText)")
            state = .idle
            return
        }

        guard tokenizer.isLoaded else {
            logger.notice("Phoneme tokenizer not loaded.")
            state = .idle
            return
        }

        do {
            try audioPlayer.start()
            state = .speaking

            for (index, phrase) in phraseQueue.enumerated() {
                let isLast = index == phraseQueue.count - 1
                await synthesizePhrase(phrase, isFinal: isLast)
            }

            let ttsLatency = CFAbsoluteTimeGetCurrent() - ttsStartTime
            logger.info("TTS synthesis latency: \(ttsLatency, format: .fixed(precision: 3))s")
        } catch {
            logger.error("TTS/playback error: \(error.localizedDescription)")
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
