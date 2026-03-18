import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey: String = ""
    @State private var showAPIKey = false
    @State private var showResetConfirmation = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.06).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        apiKeySection
                        speakerGenderSection
                        voiceProfileSection
                        aboutSection
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        saveAndDismiss()
                    }
                    .foregroundStyle(.blue)
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            apiKey = appState.anthropicAPIKey ?? ""
        }
        .alert("Reset Voice Profile?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                appState.hasCompletedEnrollment = false
                appState.voiceProfileID = nil
            }
        } message: {
            Text("This will delete your voice recordings and require re-enrollment.")
        }
    }

    // MARK: - API Key

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Claude API Key")

            HStack {
                if showAPIKey {
                    TextField("sk-ant-...", text: $apiKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.white)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } else {
                    SecureField("sk-ant-...", text: $apiKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.white)
                }

                Button {
                    showAPIKey.toggle()
                } label: {
                    Image(systemName: showAPIKey ? "eye.slash" : "eye")
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(12)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            Text("Your key is stored in the iOS Keychain and never leaves your device except to call the Anthropic API directly.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    // MARK: - Speaker Gender

    private var speakerGenderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Speaker Gender")

            HStack(spacing: 12) {
                genderButton("Male", gender: .male)
                genderButton("Female", gender: .female)
            }

            Text("Affects politeness particles in Thai translation (ครับ vs ค่ะ).")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    private func genderButton(_ label: String, gender: TranslationService.SpeakerGender) -> some View {
        Button {
            appState.speakerGender = gender
        } label: {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(appState.speakerGender == gender ? .white : .white.opacity(0.5))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    appState.speakerGender == gender ? Color.blue.opacity(0.6) : Color.white.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10)
                )
        }
    }

    // MARK: - Voice Profile

    private var voiceProfileSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Voice Profile")

            if appState.hasCompletedEnrollment {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Enrolled")
                        .foregroundStyle(.white)
                    Spacer()
                    Button("Reset") { showResetConfirmation = true }
                        .font(.system(size: 14))
                        .foregroundStyle(.red.opacity(0.8))
                }
                .padding(12)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            } else {
                HStack {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.orange)
                    Text("Not enrolled")
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Text("Complete setup to use")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .padding(12)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("About")

            VStack(alignment: .leading, spacing: 8) {
                infoRow("Translation", "Claude (Anthropic)")
                infoRow("Speech Recognition", "Apple Speech (on-device)")
                infoRow("Voice Synthesis", "Custom TTS (on-device)")
                infoRow("Languages", "English → Thai")
            }
            .padding(12)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
            .textCase(.uppercase)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text(value)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private func saveAndDismiss() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            appState.anthropicAPIKey = trimmed
        }
        dismiss()
    }
}
