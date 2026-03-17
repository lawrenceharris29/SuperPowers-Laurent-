import Foundation
import CoreML

/// On-device TTS engine using a CoreML model fine-tuned on the user's voice.
/// The actual model loading and inference will be completed after Stream 2 (GPT-4o)
/// delivers the trained model and Stream 3 (Gemini) delivers the phoneme engine.
///
/// Interface contract for the rest of the app:
/// - Load a .mlmodel from disk
/// - Accept phoneme sequence + prosody hints
/// - Return PCM audio data (16kHz, mono, float32)
@MainActor
final class CoreMLTTSEngine: ObservableObject {
    @Published var isModelLoaded = false

    private var model: MLModel?

    enum TTSError: LocalizedError {
        case modelNotLoaded
        case inferenceError(String)
        case invalidPhonemes

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded: return "TTS model not loaded"
            case .inferenceError(let msg): return "TTS inference failed: \(msg)"
            case .invalidPhonemes: return "Invalid phoneme sequence"
            }
        }
    }

    /// Load the CoreML model from a file path.
    func loadModel(at path: String) async throws {
        let url = URL(fileURLWithPath: path)
        let compiledURL = try await MLModel.compileModel(at: url)
        let config = MLModelConfiguration()
        config.computeUnits = .all // Use Neural Engine when available
        model = try MLModel(contentsOf: compiledURL, configuration: config)
        isModelLoaded = true
    }

    /// Synthesize speech from a phoneme sequence.
    /// Returns PCM audio data (16kHz, mono, float32).
    ///
    /// - Parameters:
    ///   - phonemes: IPA phoneme string (e.g., "sa˨˩.wat̚˨˩.diː˧")
    ///   - tempo: Speech rate multiplier (1.0 = normal)
    /// - Returns: Raw PCM audio data
    func synthesize(phonemes: String, tempo: Float = 1.0) async throws -> Data {
        guard let model else { throw TTSError.modelNotLoaded }

        // TODO: Implement actual inference when model format is known.
        // The model input/output schema depends on Stream 2's chosen architecture
        // (VITS vs Piper) and Stream 3's phoneme encoding format.
        //
        // Pseudocode:
        // 1. Encode phonemes to token IDs (from Stream 3's phoneme inventory)
        // 2. Create MLMultiArray with token IDs
        // 3. Create MLDictionaryFeatureProvider with tokens + tempo
        // 4. model.prediction(from: features)
        // 5. Extract audio MLMultiArray from output
        // 6. Convert to PCM Data

        _ = model // Suppress unused warning
        throw TTSError.inferenceError("Model inference not yet implemented — awaiting Streams 2 & 3")
    }

    /// Synthesize and stream audio chunks for lower latency.
    /// Yields PCM data chunks as they're generated.
    func synthesizeStreaming(phonemes: String, tempo: Float = 1.0) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    // For now, synthesize the whole thing and yield as one chunk.
                    // True streaming will depend on whether the model supports
                    // incremental decoding.
                    let audio = try await synthesize(phonemes: phonemes, tempo: tempo)
                    continuation.yield(audio)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
