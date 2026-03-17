import AVFoundation

/// Plays PCM audio chunks as they arrive, enabling low-latency streaming playback.
/// Stream 3 (Gemini) will provide the full implementation; this is the interface contract.
final class StreamingAudioPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format: AVAudioFormat

    var onPlaybackComplete: (() -> Void)?

    init(sampleRate: Double = 16000, channels: UInt32 = 1) {
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
    }

    func start() throws {
        try engine.start()
        playerNode.play()
    }

    /// Schedule a chunk of PCM audio data for playback.
    /// Chunks are queued and played in order, enabling streaming.
    func scheduleChunk(_ pcmData: Data) {
        guard let buffer = pcmBuffer(from: pcmData) else { return }
        playerNode.scheduleBuffer(buffer)
    }

    /// Schedule the final chunk and notify on completion.
    func scheduleFinalChunk(_ pcmData: Data) {
        guard let buffer = pcmBuffer(from: pcmData) else {
            onPlaybackComplete?()
            return
        }
        playerNode.scheduleBuffer(buffer) { [weak self] in
            DispatchQueue.main.async {
                self?.onPlaybackComplete?()
            }
        }
    }

    func stop() {
        playerNode.stop()
        engine.stop()
    }

    private func pcmBuffer(from data: Data) -> AVAudioPCMBuffer? {
        let frameCount = UInt32(data.count) / format.streamDescription.pointee.mBytesPerFrame
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        data.withUnsafeBytes { rawBuffer in
            if let src = rawBuffer.baseAddress,
               let dst = buffer.floatChannelData?[0] {
                memcpy(dst, src, data.count)
            }
        }
        return buffer
    }
}
