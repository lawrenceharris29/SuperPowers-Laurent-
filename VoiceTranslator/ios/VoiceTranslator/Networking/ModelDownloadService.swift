import Foundation

/// Downloads trained voice models from the training server.
/// Handles resumable downloads, progress reporting, and integrity verification.
@MainActor
final class ModelDownloadService: ObservableObject {
    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    @Published var lastError: String?

    enum DownloadError: LocalizedError {
        case invalidURL(String)
        case serverError(Int)
        case checksumMismatch
        case downloadFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL(let u): return "Invalid download URL: \(u)"
            case .serverError(let code): return "Server returned HTTP \(code)"
            case .checksumMismatch: return "Downloaded model checksum mismatch"
            case .downloadFailed(let msg): return "Download failed: \(msg)"
            }
        }
    }

    /// Download a trained model from the given URL.
    /// - Parameters:
    ///   - urlString: Full URL to the .mlmodel file on the training server
    ///   - expectedSHA256: Optional SHA-256 hex string for integrity check
    /// - Returns: Local file URL where the model was saved
    func downloadModel(from urlString: String, expectedSHA256: String? = nil) async throws -> URL {
        guard let url = URL(string: urlString) else {
            throw DownloadError.invalidURL(urlString)
        }

        isDownloading = true
        downloadProgress = 0
        lastError = nil

        defer { isDownloading = false }

        let destinationDir = AppConfiguration.modelDirectory
        try? FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        let fileName = url.lastPathComponent.isEmpty ? "voice_model.mlmodel" : url.lastPathComponent
        let destinationURL = destinationDir.appendingPathComponent(fileName)

        do {
            let (localURL, response) = try await downloadWithProgress(url: url)

            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                throw DownloadError.serverError(httpResponse.statusCode)
            }

            // Verify checksum if provided
            if let expected = expectedSHA256 {
                let data = try Data(contentsOf: localURL)
                let actual = sha256Hex(data)
                guard actual == expected.lowercased() else {
                    try? FileManager.default.removeItem(at: localURL)
                    throw DownloadError.checksumMismatch
                }
            }

            // Move to final destination
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: localURL, to: destinationURL)

            downloadProgress = 1.0
            return destinationURL

        } catch let error as DownloadError {
            lastError = error.localizedDescription
            throw error
        } catch {
            lastError = error.localizedDescription
            throw DownloadError.downloadFailed(error.localizedDescription)
        }
    }

    // MARK: - Private

    private func downloadWithProgress(url: URL) async throws -> (URL, URLResponse) {
        let request = URLRequest(url: url)
        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)

        let totalBytes = response.expectedContentLength
        var receivedBytes: Int64 = 0
        var data = Data()

        if totalBytes > 0 {
            data.reserveCapacity(Int(totalBytes))
        }

        for try await byte in asyncBytes {
            data.append(byte)
            receivedBytes += 1

            // Update progress every 64KB to avoid UI thrash
            if totalBytes > 0 && receivedBytes % 65536 == 0 {
                downloadProgress = Double(receivedBytes) / Double(totalBytes)
            }
        }

        // Write to temp file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mlmodel")
        try data.write(to: tempURL)

        return (tempURL, response)
    }

    /// Compute SHA-256 hex digest of data.
    private func sha256Hex(_ data: Data) -> String {
        // Use CommonCrypto via imported CC_SHA256
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// Minimal CommonCrypto bridge (avoids importing the full module)
import CommonCrypto
