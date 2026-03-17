import SwiftUI
import AVFoundation

struct EnrollmentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = EnrollmentViewModel()

    var body: some View {
        ZStack {
            Color(white: 0.06).ignoresSafeArea()

            VStack(spacing: 32) {
                // Header
                VStack(spacing: 8) {
                    Text("Voice Enrollment")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Record your voice so translations sound like you")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 40)

                // Progress
                progressBar

                // Current prompt
                promptCard

                Spacer()

                // Record button
                recordButton

                // Navigation
                HStack {
                    if viewModel.currentPromptIndex > 0 {
                        Button("Previous") { viewModel.previousPrompt() }
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                    if viewModel.currentPromptIndex == viewModel.prompts.count - 1
                        && viewModel.recordings.count == viewModel.prompts.count {
                        Button("Finish") { finishEnrollment() }
                            .font(.headline)
                            .foregroundStyle(.green)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
        }
    }

    private var progressBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(0..<viewModel.prompts.count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(segmentColor(for: i))
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, 32)

            Text("\(viewModel.recordings.count) / \(viewModel.prompts.count) recorded")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private func segmentColor(for index: Int) -> Color {
        if viewModel.recordings[index] != nil {
            return .green
        } else if index == viewModel.currentPromptIndex {
            return .blue
        } else {
            return .white.opacity(0.15)
        }
    }

    private var promptCard: some View {
        let prompt = viewModel.prompts[viewModel.currentPromptIndex]
        return VStack(spacing: 16) {
            Text(prompt.category)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.blue)
                .textCase(.uppercase)

            Text(prompt.text)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineSpacing(6)

            if let romanization = prompt.romanization {
                Text(romanization)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
            }

            if let translation = prompt.translation {
                Text(translation)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.3))
                    .italic()
            }
        }
        .padding(24)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 24)
    }

    private var recordButton: some View {
        Button {
            if viewModel.isRecording {
                viewModel.stopRecording()
            } else {
                viewModel.startRecording()
            }
        } label: {
            Circle()
                .fill(viewModel.isRecording ? .red : .blue.opacity(0.8))
                .frame(width: 80, height: 80)
                .overlay(
                    Group {
                        if viewModel.isRecording {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.white)
                                .frame(width: 24, height: 24)
                        } else {
                            Circle()
                                .fill(.red)
                                .frame(width: 24, height: 24)
                        }
                    }
                )
                .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 2))
        }
    }

    private func finishEnrollment() {
        // TODO: Upload recordings to training pipeline
        // For now, mark enrollment as complete
        appState.hasCompletedEnrollment = true
        appState.voiceProfileID = UUID().uuidString
    }
}

// MARK: - ViewModel

@MainActor
final class EnrollmentViewModel: ObservableObject {
    struct RecordingPrompt: Identifiable {
        let id = UUID()
        let category: String
        let text: String
        let romanization: String?
        let translation: String?
    }

    @Published var currentPromptIndex = 0
    @Published var isRecording = false
    @Published var recordings: [Int: URL] = [:]

    private var audioRecorder: AVAudioRecorder?

    let prompts: [RecordingPrompt] = [
        // English passages for timbre capture
        RecordingPrompt(
            category: "English - Natural",
            text: "The morning sun cast long shadows across the quiet street. I walked slowly, thinking about the day ahead and wondering what it might bring.",
            romanization: nil,
            translation: nil
        ),
        RecordingPrompt(
            category: "English - Excited",
            text: "That's amazing! I can't believe we actually did it! This is the best news I've heard all week!",
            romanization: nil,
            translation: nil
        ),
        RecordingPrompt(
            category: "English - Calm",
            text: "Take a deep breath. Everything is going to be fine. We have plenty of time to figure this out together.",
            romanization: nil,
            translation: nil
        ),
        // Sustained vowels
        RecordingPrompt(
            category: "Vowels",
            text: "Say each vowel for 3 seconds:\nAhhh... Eeee... Oooo... Uuuu...",
            romanization: nil,
            translation: "Hold each sound steady and natural"
        ),
        // Thai phoneme coverage (romanized for non-Thai speakers)
        RecordingPrompt(
            category: "Thai Syllables",
            text: "สวัสดีครับ ผมชื่อ... ยินดีที่ได้รู้จัก",
            romanization: "sa-wat-dee krap, phom cheu... yin-dee tee dai roo-jak",
            translation: "Hello, my name is... Nice to meet you"
        ),
        RecordingPrompt(
            category: "Thai Syllables",
            text: "ขอบคุณมากครับ ไม่เป็นไรครับ",
            romanization: "khop-khun maak krap, mai pen rai krap",
            translation: "Thank you very much. You're welcome."
        ),
        RecordingPrompt(
            category: "Thai Tones",
            text: "กา ก่า ก้า ก๊า ก๋า",
            romanization: "gaa gàa gâa gáa gǎa",
            translation: "Five tones: mid, low, falling, high, rising"
        ),
        RecordingPrompt(
            category: "Thai Tones",
            text: "มา ม่า ม้า ม๊า ม๋า",
            romanization: "maa màa mâa máa mǎa",
            translation: "Five tones with 'ma' initial"
        ),
        // Note: Full enrollment script will come from Stream 4 (Kimi)
        // These are placeholder prompts — the real set will have 50-70 sentences
    ]

    func startRecording() {
        let url = getRecordingURL(for: currentPromptIndex)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.record()
            isRecording = true
        } catch {
            print("[Enrollment] Recording failed: \(error)")
        }
    }

    func stopRecording() {
        audioRecorder?.stop()
        isRecording = false
        recordings[currentPromptIndex] = getRecordingURL(for: currentPromptIndex)

        // Auto-advance to next prompt
        if currentPromptIndex < prompts.count - 1 {
            currentPromptIndex += 1
        }
    }

    func previousPrompt() {
        if currentPromptIndex > 0 {
            currentPromptIndex -= 1
        }
    }

    private func getRecordingURL(for index: Int) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("enrollment_\(index).wav")
    }
}
