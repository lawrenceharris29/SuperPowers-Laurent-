import Foundation

struct VoiceProfile: Codable, Identifiable {
    let id: String
    let name: String
    let createdAt: Date
    let sampleCount: Int
    let totalDurationSeconds: Double
    var modelPath: String? // Path to the CoreML model fine-tuned on this voice
}

struct TranslationEntry: Identifiable {
    let id = UUID()
    let sourceText: String
    let translatedText: String
    let timestamp: Date
}
