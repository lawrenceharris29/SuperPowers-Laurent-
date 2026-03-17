import Foundation
import AVFoundation
import Accelerate

public enum AudioUtilities {

    /// Reads a WAV file and returns PCM Float32 data.
    public static func readWAV(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: file.fileFormat.sampleRate,
                                         channels: file.fileFormat.channelCount,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "AudioUtilities", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create format or buffer"])
        }

        try file.read(into: buffer)
        guard let floatChannelData = buffer.floatChannelData else { return [] }

        let frameLength = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: floatChannelData[0], count: frameLength))
    }

    /// Writes PCM Float32 data to a WAV file.
    public static func writeWAV(pcmData: [Float], sampleRate: Double, channels: AVAudioChannelCount, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: channels,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcmData.count)) else {
            throw NSError(domain: "AudioUtilities", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create buffer for writing"])
        }

        buffer.frameLength = buffer.frameCapacity
        guard let floatChannelData = buffer.floatChannelData else { return }

        pcmData.withUnsafeBufferPointer { ptr in
            if let baseAddress = ptr.baseAddress {
                floatChannelData[0].initialize(from: baseAddress, count: pcmData.count)
            }
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    /// Normalizes audio to target peak level (-1.0 to 1.0) via vDSP.
    public static func normalize(pcmData: inout [Float], targetPeak: Float = 0.95) {
        var maxVal: Float = 0
        vDSP_maxmgv(pcmData, 1, &maxVal, vDSP_Length(pcmData.count))

        if maxVal > 0 {
            let scale = targetPeak / maxVal
            var scaleVal = scale
            vDSP_vsmul(pcmData, 1, &scaleVal, &pcmData, 1, vDSP_Length(pcmData.count))
        }
    }

    /// Converts PCM Float32 data to raw bytes (Data) for StreamingAudioPlayer.
    public static func floatToData(_ pcmData: [Float]) -> Data {
        return pcmData.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }
}
