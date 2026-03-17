import Foundation

/// Polls the training server for job status after enrollment recordings are uploaded.
/// Notifies the app when the model is ready for download.
@MainActor
final class TrainingStatusService: ObservableObject {

    enum TrainingStatus: Equatable {
        case unknown
        case queued(position: Int?)
        case processing(progress: Double)
        case completed(modelURL: String, sha256: String?)
        case failed(reason: String)
    }

    @Published var status: TrainingStatus = .unknown
    @Published var isPolling = false

    private var pollTask: Task<Void, Never>?
    private let pollInterval: TimeInterval = 15 // seconds between polls

    /// Server response format for training status.
    private struct StatusResponse: Codable {
        let status: String              // "queued", "processing", "completed", "failed"
        let progress: Double?           // 0.0–1.0 for "processing"
        let queuePosition: Int?         // for "queued"
        let modelURL: String?           // for "completed"
        let modelSHA256: String?        // for "completed"
        let failureReason: String?      // for "failed"
    }

    /// Start polling a training job for status updates.
    /// - Parameters:
    ///   - statusURL: The URL returned by the upload response
    ///   - onComplete: Called once when training finishes (success or failure)
    func startPolling(statusURL: String, onComplete: @escaping (TrainingStatus) -> Void) {
        stopPolling()

        guard let url = URL(string: statusURL) else {
            status = .failed(reason: "Invalid status URL")
            onComplete(status)
            return
        }

        isPolling = true

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                let currentStatus = await self.fetchStatus(url: url)
                self.status = currentStatus

                switch currentStatus {
                case .completed, .failed:
                    self.isPolling = false
                    onComplete(currentStatus)
                    return
                default:
                    break
                }

                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
            }
        }
    }

    /// Stop polling.
    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
    }

    /// One-shot status check (no polling loop).
    func checkStatus(statusURL: String) async -> TrainingStatus {
        guard let url = URL(string: statusURL) else {
            return .failed(reason: "Invalid status URL")
        }
        return await fetchStatus(url: url)
    }

    // MARK: - Private

    private func fetchStatus(url: URL) async -> TrainingStatus {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                return .failed(reason: "Server returned HTTP \(httpResponse.statusCode)")
            }

            let decoded = try JSONDecoder().decode(StatusResponse.self, from: data)

            switch decoded.status {
            case "queued":
                return .queued(position: decoded.queuePosition)
            case "processing":
                return .processing(progress: decoded.progress ?? 0)
            case "completed":
                if let modelURL = decoded.modelURL {
                    return .completed(modelURL: modelURL, sha256: decoded.modelSHA256)
                }
                return .failed(reason: "Completed but no model URL returned")
            case "failed":
                return .failed(reason: decoded.failureReason ?? "Unknown training failure")
            default:
                return .unknown
            }
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }
}
