import Foundation
import CoreML
import os.log

/// On-device TTS engine using a VITS CoreML model fine-tuned on the user's voice.
///
/// Input: phoneme token IDs + duration arrays (from PhonemeTokenizer + ProsodyModel)
/// Output: PCM Float32 audio at 22050 Hz
///
/// Uses Neural Engine when available for low-latency inference.
@MainActor
final class CoreMLTTSEngine: ObservableObject {
    @Published var isModelLoaded = false

    private var model: MLModel?
    private let logger = Logger(subsystem: "com.voicetranslator", category: "CoreMLTTS")

    enum TTSError: LocalizedError {
        case modelNotLoaded
        case inferenceError(String)
        case invalidInput(String)

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded: return "TTS model not loaded"
            case .inferenceError(let msg): return "TTS inference failed: \(msg)"
            case .invalidInput(let msg): return "Invalid TTS input: \(msg)"
            }
        }
    }

    /// Load and prewarm the VITS CoreML model.
    func loadModel(at path: String) async throws {
        let url = URL(fileURLWithPath: path)
        try await loadModel(url: url)
    }

    /// Load from a URL (supports both file and compiled model URLs).
    func loadModel(url: URL) async throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all // Leverages Neural Engine where available

        // Load on background thread to prevent UI hang
        let loadedModel = try await Task.detached {
            let compiledURL = try MLModel.compileModel(at: url)
            return try MLModel(contentsOf: compiledURL, configuration: config)
        }.value

        model = loadedModel
        isModelLoaded = true
        logger.info("CoreML TTS model loaded successfully.")
    }

    /// Unload the model to free memory.
    func unload() {
        model = nil
        isModelLoaded = false
        logger.info("CoreML TTS model unloaded.")
    }

    /// Synthesize speech from phoneme token IDs and durations.
    ///
    /// - Parameters:
    ///   - phonemeIDs: Token IDs from PhonemeTokenizer
    ///   - durations: Per-phoneme durations in ms from ProsodyModel
    /// - Returns: PCM Float32 audio samples (22050 Hz, mono)
    func synthesize(phonemeIDs: [Int32], durations: [Int32]) async throws -> [Float] {
        guard let model else { throw TTSError.modelNotLoaded }
        guard !phonemeIDs.isEmpty else { throw TTSError.invalidInput("Empty phoneme IDs") }

        let seqLen = phonemeIDs.count

        guard let idArray = try? MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32),
              let durArray = try? MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32) else {
            throw TTSError.inferenceError("Failed to create MLMultiArrays")
        }

        for i in 0..<seqLen {
            idArray[[0, NSNumber(value: i)]] = NSNumber(value: phonemeIDs[i])
            durArray[[0, NSNumber(value: i)]] = NSNumber(value: i < durations.count ? durations[i] : 200)
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "phoneme_ids": idArray,
            "durations": durArray
        ])

        // Run inference on background thread
        let capturedModel = model
        let output = try await Task.detached(priority: .userInitiated) {
            return try capturedModel.prediction(from: provider)
        }.value

        // Extract PCM from output tensor (expected shape: [1, 1, audio_len])
        guard let audioOutput = output.featureValue(for: "audio_output")?.multiArrayValue else {
            throw TTSError.inferenceError("Invalid output tensor — expected 'audio_output' key")
        }

        let count = audioOutput.count
        var pcmData = [Float](repeating: 0.0, count: count)

        let ptr = audioOutput.dataPointer.bindMemory(to: Float.self, capacity: count)
        let buffer = UnsafeBufferPointer(start: ptr, count: count)
        _ = pcmData.withUnsafeMutableBufferPointer { $0.update(from: buffer) }

        logger.info("Synthesized \(count) audio samples (\(Double(count) / 22050.0, format: .fixed(precision: 2))s)")
        return pcmData
    }

    /// Convenience: synthesize from IPA phoneme string using tokenizer and default durations.
    func synthesize(phonemes: String, tokenizer: PhonemeTokenizer, tempo: Float = 1.0) async throws -> [Float] {
        let tokenIDs = try tokenizer.tokenize(phonemes)
        // Default duration of 200ms per token, scaled by tempo
        let baseDuration = Int32(Float(200) / tempo)
        let durations = [Int32](repeating: baseDuration, count: tokenIDs.count)
        return try await synthesize(phonemeIDs: tokenIDs, durations: durations)
    }
}
