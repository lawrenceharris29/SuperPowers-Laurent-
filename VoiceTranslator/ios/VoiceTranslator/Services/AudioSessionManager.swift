import AVFoundation

final class AudioSessionManager {
    static let shared = AudioSessionManager()

    private init() {}

    func configure() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
            try session.setPreferredSampleRate(16000)
            try session.setPreferredIOBufferDuration(0.02) // 20ms buffer for low latency
            try session.setActive(true)
        } catch {
            print("[AudioSession] Configuration failed: \(error.localizedDescription)")
        }
    }

    func activateForRecording() {
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            print("[AudioSession] Activate for recording failed: \(error)")
        }
    }

    func activateForPlayback() {
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
        } catch {
            print("[AudioSession] Speaker override failed: \(error)")
        }
    }
}
