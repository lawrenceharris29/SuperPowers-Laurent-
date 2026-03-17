import Foundation
import CoreML

/// Manages trained voice profile models on disk.
/// Handles saving, loading, listing, and deleting CoreML models
/// that have been fine-tuned on the user's voice.
@MainActor
final class VoiceProfileManager: ObservableObject {
    @Published var activeProfile: VoiceProfile?
    @Published var availableProfiles: [VoiceProfile] = []

    private let fileManager = FileManager.default
    private let profilesKey = "voice_profiles"

    enum ProfileError: LocalizedError {
        case profileNotFound(String)
        case modelNotFound(String)
        case saveFailed(String)
        case compilationFailed(String)

        var errorDescription: String? {
            switch self {
            case .profileNotFound(let id): return "Voice profile not found: \(id)"
            case .modelNotFound(let path): return "Model file not found: \(path)"
            case .saveFailed(let msg): return "Failed to save profile: \(msg)"
            case .compilationFailed(let msg): return "Model compilation failed: \(msg)"
            }
        }
    }

    init() {
        ensureDirectoriesExist()
        loadProfileIndex()
    }

    /// Save a trained model file and create a VoiceProfile entry.
    /// - Parameters:
    ///   - modelData: Raw .mlmodel file data from the training server
    ///   - name: Display name for this profile
    ///   - sampleCount: Number of enrollment recordings used
    ///   - totalDuration: Total seconds of enrollment audio
    /// - Returns: The created VoiceProfile
    @discardableResult
    func saveModel(
        _ modelData: Data,
        name: String,
        sampleCount: Int,
        totalDuration: Double
    ) throws -> VoiceProfile {
        let profileID = UUID().uuidString
        let modelFileName = "voice_\(profileID).mlmodel"
        let modelURL = AppConfiguration.modelDirectory.appendingPathComponent(modelFileName)

        // Write raw model to disk
        do {
            try modelData.write(to: modelURL)
        } catch {
            throw ProfileError.saveFailed(error.localizedDescription)
        }

        let profile = VoiceProfile(
            id: profileID,
            name: name,
            createdAt: Date(),
            sampleCount: sampleCount,
            totalDurationSeconds: totalDuration,
            modelPath: modelURL.path
        )

        availableProfiles.append(profile)
        saveProfileIndex()

        return profile
    }

    /// Save a model that's already been downloaded to a local URL.
    @discardableResult
    func saveModelFromFile(
        at sourceURL: URL,
        name: String,
        sampleCount: Int,
        totalDuration: Double
    ) throws -> VoiceProfile {
        let data = try Data(contentsOf: sourceURL)
        return try saveModel(data, name: name, sampleCount: sampleCount, totalDuration: totalDuration)
    }

    /// Set a profile as the active voice for TTS.
    func activate(profileID: String) throws {
        guard let profile = availableProfiles.first(where: { $0.id == profileID }) else {
            throw ProfileError.profileNotFound(profileID)
        }
        guard let path = profile.modelPath,
              fileManager.fileExists(atPath: path) else {
            throw ProfileError.modelNotFound(profile.modelPath ?? "nil")
        }
        activeProfile = profile
        KeychainHelper.save(key: "active_voice_profile", value: profileID)
    }

    /// Load the CoreML model for the active profile into a TTS engine.
    func loadActiveModel(into engine: CoreMLTTSEngine) async throws {
        guard let profile = activeProfile,
              let path = profile.modelPath else {
            throw ProfileError.profileNotFound("no active profile")
        }
        try await engine.loadModel(at: path)
    }

    /// Delete a voice profile and its model file.
    func deleteProfile(id: String) throws {
        guard let index = availableProfiles.firstIndex(where: { $0.id == id }) else {
            throw ProfileError.profileNotFound(id)
        }

        let profile = availableProfiles[index]

        // Delete model file
        if let path = profile.modelPath {
            try? fileManager.removeItem(atPath: path)
        }

        availableProfiles.remove(at: index)

        // Clear active if this was it
        if activeProfile?.id == id {
            activeProfile = nil
            KeychainHelper.delete(key: "active_voice_profile")
        }

        saveProfileIndex()
    }

    /// Delete all profiles and model files.
    func deleteAllProfiles() {
        for profile in availableProfiles {
            if let path = profile.modelPath {
                try? fileManager.removeItem(atPath: path)
            }
        }
        availableProfiles.removeAll()
        activeProfile = nil
        KeychainHelper.delete(key: "active_voice_profile")
        saveProfileIndex()
    }

    /// Restore active profile from Keychain on app launch.
    func restoreActiveProfile() {
        guard let savedID = KeychainHelper.load(key: "active_voice_profile"),
              let profile = availableProfiles.first(where: { $0.id == savedID }),
              let path = profile.modelPath,
              fileManager.fileExists(atPath: path) else {
            return
        }
        activeProfile = profile
    }

    // MARK: - Private

    private func ensureDirectoriesExist() {
        try? fileManager.createDirectory(
            at: AppConfiguration.modelDirectory,
            withIntermediateDirectories: true
        )
    }

    private func loadProfileIndex() {
        let indexURL = AppConfiguration.modelDirectory.appendingPathComponent("profiles.json")
        guard let data = try? Data(contentsOf: indexURL) else { return }
        availableProfiles = (try? JSONDecoder().decode([VoiceProfile].self, from: data)) ?? []
    }

    private func saveProfileIndex() {
        let indexURL = AppConfiguration.modelDirectory.appendingPathComponent("profiles.json")
        guard let data = try? JSONEncoder().encode(availableProfiles) else { return }
        try? data.write(to: indexURL)
    }
}
