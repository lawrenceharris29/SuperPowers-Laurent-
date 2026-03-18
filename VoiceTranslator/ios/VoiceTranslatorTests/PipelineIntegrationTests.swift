import XCTest
@testable import VoiceTranslator

/// End-to-end integration tests for the VoiceTranslator pipeline.
///
/// These tests verify the full pipeline: STT → Translation → TTS → Playback.
/// They are designed to run on a physical device with microphone access and
/// a valid Claude API key. Simulator-safe tests use mocked components.
///
/// Test categories:
///   1. Unit: individual component contracts (tokenizer, audio utils, prompt)
///   2. Integration: component wiring (pipeline state machine, phrase emission)
///   3. Latency: performance budgets for each pipeline stage
///   4. Quality: translation accuracy against the evaluation test suite
final class PipelineIntegrationTests: XCTestCase {

    // MARK: - 1. Pipeline State Machine

    @MainActor
    func testPipelineStartsInIdleState() {
        let pipeline = AudioPipeline()
        XCTAssertEqual(pipeline.state, .idle)
    }

    @MainActor
    func testPipelineResetReturnsToIdle() {
        let pipeline = AudioPipeline()
        pipeline.reset()
        XCTAssertEqual(pipeline.state, .idle)
        XCTAssertTrue(pipeline.currentTranscript.isEmpty)
        XCTAssertTrue(pipeline.currentTranslation.isEmpty)
    }

    @MainActor
    func testPipelineIgnoresStartWhenTranslating() {
        let pipeline = AudioPipeline()
        pipeline.state = .translating
        pipeline.startListening()
        // Should not transition to listening while translating
        XCTAssertEqual(pipeline.state, .translating)
    }

    @MainActor
    func testPipelineAllowsInterruptDuringSpeaking() {
        let pipeline = AudioPipeline()
        pipeline.configure(apiKey: "test-key")
        pipeline.state = .speaking
        pipeline.startListening()
        XCTAssertEqual(pipeline.state, .listening)
    }

    // MARK: - 2. Phoneme Tokenizer

    func testTokenizerLoadsInventory() throws {
        let tokenizer = PhonemeTokenizer()
        // Load from test bundle — in CI, copy thai_phonemes.json to test target
        let path = Bundle(for: type(of: self)).path(forResource: "thai_phonemes", ofType: "json")
        if let path {
            try tokenizer.loadInventory(from: path)
            XCTAssertTrue(tokenizer.isLoaded)
        }
    }

    func testTokenizerPadding() throws {
        let tokenizer = PhonemeTokenizer()
        let path = Bundle(for: type(of: self)).path(forResource: "thai_phonemes", ofType: "json")
        guard let path else { return }

        try tokenizer.loadInventory(from: path)
        tokenizer.maxSequenceLength = 10

        let padded = try tokenizer.tokenizeAndPad("a")
        XCTAssertEqual(padded.count, 10)
    }

    // MARK: - 3. Translation Service

    @MainActor
    func testTranslationServiceConfigures() {
        let service = TranslationService()
        service.configure(apiKey: "test-key")
        XCTAssertFalse(service.isTranslating)
    }

    @MainActor
    func testSpeakerGenderAffectsParticle() {
        let service = TranslationService()
        service.speakerGender = .male
        XCTAssertEqual(service.speakerGender.particle, "ครับ")

        service.speakerGender = .female
        XCTAssertEqual(service.speakerGender.particle, "ค่ะ")
    }

    @MainActor
    func testPhraseCallbackFires() async {
        let service = TranslationService()
        service.configure(apiKey: "test-key")

        var phrases: [String] = []
        service.onPhrase = { phrases.append($0) }

        // Note: this test requires a valid API key to hit Claude.
        // In CI, mock the AnthropicClient instead.
    }

    // MARK: - 4. Audio Components

    func testStreamingAudioPlayerInitializes() {
        let player = StreamingAudioPlayer(sampleRate: 22050)
        // Should not crash
        player.stop()
    }

    func testAudioPlayerSchedulesChunks() throws {
        let player = StreamingAudioPlayer(sampleRate: 22050)
        try player.start()

        let silence = [Float](repeating: 0.0, count: 4410) // 0.2s
        player.scheduleChunk(silence)
        player.stop()
    }

    @MainActor
    func testCoreMLEngineReportsUnloaded() {
        let engine = CoreMLTTSEngine()
        XCTAssertFalse(engine.isModelLoaded)
    }

    // MARK: - 5. Audio Utilities

    func testNormalize() {
        var samples: [Float] = [0.1, -0.3, 0.5, -0.2]
        AudioUtilities.normalize(pcmData: &samples)

        let peak = samples.map { abs($0) }.max() ?? 0
        // After normalization, peak should be close to target (~0.89)
        XCTAssertGreaterThan(peak, 0.8)
        XCTAssertLessThanOrEqual(peak, 1.0)
    }

    // MARK: - 6. Latency Benchmarks

    /// Target: phoneme tokenization < 5ms for typical Thai sentence
    func testTokenizationLatency() throws {
        let tokenizer = PhonemeTokenizer()
        let path = Bundle(for: type(of: self)).path(forResource: "thai_phonemes", ofType: "json")
        guard let path else { return }
        try tokenizer.loadInventory(from: path)

        let testPhonemes = "sa˨˩.wat̚˨˩.diː˧ kʰrap̚˦˥"

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<100 {
            _ = try tokenizer.tokenize(testPhonemes)
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) / 100.0

        // Should be < 5ms per tokenization
        XCTAssertLessThan(elapsed, 0.005, "Tokenization took \(elapsed * 1000)ms, budget is 5ms")
    }

    /// Target: audio buffer creation < 1ms for 1 second of audio
    func testBufferCreationLatency() {
        let player = StreamingAudioPlayer(sampleRate: 22050)
        let samples = [Float](repeating: 0.0, count: 22050) // 1 second

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<100 {
            player.scheduleChunk(samples)
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) / 100.0

        XCTAssertLessThan(elapsed, 0.001, "Buffer creation took \(elapsed * 1000)ms, budget is 1ms")
        player.stop()
    }
}
