import AVFoundation

/// Plays PCM audio chunks as they arrive, enabling low-latency streaming playback.
/// Accepts both raw `Data` (from network) and `[Float]` (from CoreML TTS).
final class StreamingAudioPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format: AVAudioFormat

    var onPlaybackComplete: (() -> Void)?

    init(sampleRate: Double = 22050, channels: UInt32 = 1) {
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
        if !engine.isRunning {
            try engine.start()
        }
        playerNode.play()
    }

    /// Schedule Float32 PCM samples for playback (from CoreML TTS output).
    func scheduleChunk(_ pcmSamples: [Float]) {
        guard let buffer = pcmBuffer(from: pcmSamples) else { return }
        playerNode.scheduleBuffer(buffer)
    }

    /// Schedule the final chunk of Float32 samples and notify on completion.
    func scheduleFinalChunk(_ pcmSamples: [Float]) {
        guard let buffer = pcmBuffer(from: pcmSamples) else {
            onPlaybackComplete?()
            return
        }
        playerNode.scheduleBuffer(buffer) { [weak self] in
            DispatchQueue.main.async {
                self?.onPlaybackComplete?()
            }
        }
    }

    /// Schedule raw PCM Data for playback (legacy interface).
    func scheduleChunk(_ pcmData: Data) {
        guard let buffer = pcmBuffer(fromData: pcmData) else { return }
        playerNode.scheduleBuffer(buffer)
    }

    /// Schedule the final chunk of raw Data and notify on completion.
    func scheduleFinalChunk(_ pcmData: Data) {
        guard let buffer = pcmBuffer(fromData: pcmData) else {
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
        if engine.isRunning {
            engine.stop()
        }
    }

    // MARK: - Buffer Conversion

    private func pcmBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        let frameCount = UInt32(samples.count)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        if let dst = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                if let baseAddress = src.baseAddress {
                    dst.initialize(from: baseAddress, count: samples.count)
                }
            }
        }
        return buffer
    }

    private func pcmBuffer(fromData data: Data) -> AVAudioPCMBuffer? {
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
