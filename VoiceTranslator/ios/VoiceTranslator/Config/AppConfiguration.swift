import Foundation

enum AppConfiguration {
    // Translation
    static let defaultModel = "claude-sonnet-4-20250514"
    static let maxConversationHistory = 5 // pairs

    // Audio
    static let sampleRate: Double = 16000
    static let channels: UInt32 = 1
    static let bitDepth = 16
    static let ioBufferDuration: TimeInterval = 0.02 // 20ms

    // Speech Recognition
    static let silenceTimeout: TimeInterval = 1.5
    static let locale = "en-US"

    // TTS
    static let ttsModelFileName = "voice_model.mlmodel"
    static let phonemeInventoryFileName = "thai_phonemes.json"

    // Enrollment
    static let minimumRecordingsRequired = 8

    // Training Server
    static let trainingServerBaseURL = "https://api.voicetranslator.app/v1"
    static let enrollmentUploadPath = "/enrollment/upload"
    static let trainingStatusPath = "/training/status"

    // Paths
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var enrollmentDirectory: URL {
        documentsDirectory.appendingPathComponent("enrollment", isDirectory: true)
    }

    static var modelDirectory: URL {
        documentsDirectory.appendingPathComponent("models", isDirectory: true)
    }
}
