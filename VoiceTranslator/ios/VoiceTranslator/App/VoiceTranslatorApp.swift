import SwiftUI

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

    init() {
        self.hasCompletedEnrollment = UserDefaults.standard.bool(forKey: "hasCompletedEnrollment")
        self.voiceProfileID = KeychainHelper.load(key: "voiceProfileID")
        self.anthropicAPIKey = KeychainHelper.load(key: "anthropicAPIKey")
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
