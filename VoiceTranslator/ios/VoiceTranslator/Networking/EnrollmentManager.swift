import Foundation

/// Packages enrollment recordings and uploads them to the training pipeline.
/// This bridges the gap between the EnrollmentView (records WAV files locally)
/// and the training server (Stream 2) that produces a fine-tuned TTS model.
@MainActor
final class EnrollmentManager: ObservableObject {
    @Published var uploadProgress: Double = 0
    @Published var isUploading = false
    @Published var lastError: String?

    enum UploadError: LocalizedError {
        case noRecordings
        case packagingFailed(String)
        case uploadFailed(String)
        case serverError(Int, String)

        var errorDescription: String? {
            switch self {
            case .noRecordings: return "No recordings found to upload"
            case .packagingFailed(let m): return "Failed to package recordings: \(m)"
            case .uploadFailed(let m): return "Upload failed: \(m)"
            case .serverError(let code, let m): return "Server error \(code): \(m)"
            }
        }
    }

    /// Response from the training server after a successful upload.
    struct UploadResponse: Codable {
        let jobID: String
        let estimatedDurationSeconds: Int?
        let statusURL: String
    }

    /// Metadata sent alongside the recordings.
    struct EnrollmentMetadata: Codable {
        let deviceID: String
        let recordingCount: Int
        let sampleRate: Int
        let bitDepth: Int
        let channels: Int
        let totalDurationSeconds: Double
        let prompts: [PromptMetadata]
    }

    struct PromptMetadata: Codable {
        let index: Int
        let category: String
        let text: String
        let fileName: String
        let durationSeconds: Double?
    }

    /// Package recordings into a ZIP-like bundle and upload to the training server.
    ///
    /// - Parameters:
    ///   - recordings: Map of prompt index → local WAV file URL
    ///   - prompts: The recording prompts (for metadata alignment)
    ///   - serverURL: Training pipeline upload endpoint
    /// - Returns: UploadResponse with the training job ID
    func uploadRecordings(
        recordings: [Int: URL],
        prompts: [(category: String, text: String)],
        serverURL: String
    ) async throws -> UploadResponse {
        guard !recordings.isEmpty else { throw UploadError.noRecordings }
        guard let uploadURL = URL(string: serverURL) else {
            throw UploadError.uploadFailed("Invalid server URL: \(serverURL)")
        }

        isUploading = true
        uploadProgress = 0
        lastError = nil

        defer { isUploading = false }

        do {
            // Build multipart form data
            let boundary = "VoiceTranslator-\(UUID().uuidString)"
            var body = Data()

            // Add metadata JSON
            let promptMetadata: [PromptMetadata] = recordings.map { index, url in
                PromptMetadata(
                    index: index,
                    category: index < prompts.count ? prompts[index].category : "unknown",
                    text: index < prompts.count ? prompts[index].text : "",
                    fileName: url.lastPathComponent,
                    durationSeconds: audioDuration(at: url)
                )
            }

            let totalDuration = promptMetadata.compactMap(\.durationSeconds).reduce(0, +)

            let metadata = EnrollmentMetadata(
                deviceID: deviceIdentifier(),
                recordingCount: recordings.count,
                sampleRate: Int(AppConfiguration.sampleRate),
                bitDepth: AppConfiguration.bitDepth,
                channels: Int(AppConfiguration.channels),
                totalDurationSeconds: totalDuration,
                prompts: promptMetadata
            )

            let metadataJSON = try JSONEncoder().encode(metadata)
            appendMultipartField(
                to: &body,
                boundary: boundary,
                name: "metadata",
                data: metadataJSON,
                contentType: "application/json"
            )

            // Add WAV files
            let sortedRecordings = recordings.sorted(by: { $0.key < $1.key })
            for (index, entry) in sortedRecordings.enumerated() {
                let wavData = try Data(contentsOf: entry.value)
                appendMultipartFile(
                    to: &body,
                    boundary: boundary,
                    name: "recording_\(entry.key)",
                    fileName: entry.value.lastPathComponent,
                    data: wavData,
                    contentType: "audio/wav"
                )

                uploadProgress = Double(index + 1) / Double(sortedRecordings.count) * 0.9
            }

            // Close multipart
            body.append("--\(boundary)--\r\n".data(using: .utf8)!)

            // Send request
            var request = URLRequest(url: uploadURL)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body

            let (responseData, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                let message = String(data: responseData, encoding: .utf8) ?? "Unknown error"
                throw UploadError.serverError(httpResponse.statusCode, message)
            }

            uploadProgress = 1.0

            let uploadResponse = try JSONDecoder().decode(UploadResponse.self, from: responseData)
            return uploadResponse

        } catch let error as UploadError {
            lastError = error.localizedDescription
            throw error
        } catch {
            lastError = error.localizedDescription
            throw UploadError.uploadFailed(error.localizedDescription)
        }
    }

    // MARK: - Multipart Helpers

    private func appendMultipartField(to body: inout Data, boundary: String, name: String, data: Data, contentType: String) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
    }

    private func appendMultipartFile(to body: inout Data, boundary: String, name: String, fileName: String, data: Data, contentType: String) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
    }

    private func audioDuration(at url: URL) -> Double? {
        // PCM WAV: (fileSize - 44 header) / (sampleRate * channels * bytesPerSample)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? Int else { return nil }
        let dataSize = max(0, fileSize - 44)
        let bytesPerSecond = Int(AppConfiguration.sampleRate) * Int(AppConfiguration.channels) * (AppConfiguration.bitDepth / 8)
        return bytesPerSecond > 0 ? Double(dataSize) / Double(bytesPerSecond) : nil
    }

    private func deviceIdentifier() -> String {
        // Stable per-app device ID (not hardware UDID)
        let key = "device_enrollment_id"
        if let existing = KeychainHelper.load(key: key) {
            return existing
        }
        let newID = UUID().uuidString
        KeychainHelper.save(key: key, value: newID)
        return newID
    }
}
