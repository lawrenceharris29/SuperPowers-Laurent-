import Foundation
import AVFoundation
import Accelerate

/// Detects silence in audio buffers using RMS energy thresholding.
/// Used during enrollment recording and live STT to detect end-of-utterance.
public class SilenceDetector {
    private let silenceThreshold: Float
    private let minimumSilenceDuration: TimeInterval
    private var silenceStartTime: Date?

    public var onSilenceDetected: (() -> Void)?

    public init(thresholdDB: Float = -40.0, minimumDuration: TimeInterval = 1.0) {
        // Convert dB to linear RMS threshold
        self.silenceThreshold = pow(10.0, thresholdDB / 20.0)
        self.minimumSilenceDuration = minimumDuration
    }

    public func process(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = vDSP_Length(buffer.frameLength)

        var rms: Float = 0
        vDSP_rmsqv(channelData[0], 1, &rms, frameLength)

        if rms < silenceThreshold {
            if let start = silenceStartTime {
                if Date().timeIntervalSince(start) >= minimumSilenceDuration {
                    onSilenceDetected?()
                    silenceStartTime = nil
                }
            } else {
                silenceStartTime = Date()
            }
        } else {
            silenceStartTime = nil
        }
    }

    public func reset() {
        silenceStartTime = nil
    }
}
