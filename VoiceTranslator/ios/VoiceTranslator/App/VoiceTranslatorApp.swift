import SwiftUI
import os.log

@main
struct VoiceTranslatorApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .onAppear {
                    AudioSessionManager.shared.configure()
                }
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var hasCompletedEnrollment: Bool {
        didSet { UserDefaults.standard.set(hasCompletedEnrollment, forKey: "hasCompletedEnrollment") }
    }
    @Published var voiceProfileID: String? {
        didSet { KeychainHelper.save(key: "voiceProfileID", value: voiceProfileID ?? "") }
    }
    @Published var anthropicAPIKey: String? {
        didSet { KeychainHelper.save(key: "anthropicAPIKey", value: anthropicAPIKey ?? "") }
    }
    @Published var speakerGender: TranslationService.SpeakerGender {
        didSet { UserDefaults.standard.set(speakerGender.rawValue, forKey: "speakerGender") }
    }

    /// Voice profile manager for model lifecycle
    let profileManager = VoiceProfileManager()

    private let logger = Logger(subsystem: "com.voicetranslator", category: "AppState")

    init() {
        self.hasCompletedEnrollment = UserDefaults.standard.bool(forKey: "hasCompletedEnrollment")
        self.voiceProfileID = KeychainHelper.load(key: "voiceProfileID")
        self.anthropicAPIKey = KeychainHelper.load(key: "anthropicAPIKey")

        let genderRaw = UserDefaults.standard.string(forKey: "speakerGender") ?? "male"
        self.speakerGender = TranslationService.SpeakerGender(rawValue: genderRaw) ?? .male

        // Restore active voice profile from Keychain
        profileManager.restoreActiveProfile()
    }

    /// Auto-loads the active voice model into a pipeline's TTS engine.
    /// Call this when the translation view appears.
    func loadVoiceModel(into pipeline: AudioPipeline) {
        guard profileManager.activeProfile != nil else {
            logger.info("No active voice profile to load.")
            return
        }

        Task {
            do {
                try await profileManager.loadActiveModel(into: pipeline.ttsEngine)
                logger.info("Voice model loaded successfully.")
            } catch {
                logger.error("Failed to load voice model: \(error.localizedDescription)")
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if appState.anthropicAPIKey == nil || appState.anthropicAPIKey?.isEmpty == true {
            SettingsView()
        } else if !appState.hasCompletedEnrollment {
            EnrollmentView()
        } else {
            TranslationView()
        }
    }
}
