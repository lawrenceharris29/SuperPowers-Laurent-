import SwiftUI

struct TranslationView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var pipeline = AudioPipeline()
    @State private var isPressed = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            // Background
            backgroundColor
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar: settings gear + language indicator
                HStack {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    Text("EN → TH")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.1), in: Capsule())
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                Spacer()

                // State indicator
                stateIndicator

                Spacer()

                // The button
                walkieTalkieButton
                    .padding(.bottom, 60)
            }
        }
        .onAppear {
            if let key = appState.anthropicAPIKey {
                pipeline.configure(apiKey: key)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    // MARK: - Walkie-Talkie Button

    private var walkieTalkieButton: some View {
        Circle()
            .fill(buttonColor)
            .frame(width: 140, height: 140)
            .overlay(
                Circle()
                    .strokeBorder(.white.opacity(0.2), lineWidth: 2)
            )
            .overlay(buttonIcon)
            .scaleEffect(isPressed ? 1.1 : 1.0)
            .shadow(color: buttonGlow, radius: isPressed ? 30 : 10)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed {
                            isPressed = true
                            hapticFeedback(.heavy)
                            Task { await requestPermissionsAndStart() }
                        }
                    }
                    .onEnded { _ in
                        isPressed = false
                        hapticFeedback(.light)
                        pipeline.stopListening()
                    }
            )
            .animation(.spring(response: 0.3), value: isPressed)
            .animation(.easeInOut(duration: 0.3), value: pipeline.state)
    }

    private var buttonIcon: some View {
        Group {
            switch pipeline.state {
            case .idle:
                Image(systemName: "mic.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white)
            case .listening:
                Image(systemName: "waveform")
                    .font(.system(size: 40))
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative)
            case .translating:
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.5)
            case .synthesizing, .speaking:
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.yellow)
            }
        }
    }

    // MARK: - State Indicator

    private var stateIndicator: some View {
        VStack(spacing: 8) {
            switch pipeline.state {
            case .idle:
                Text("Hold to speak")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            case .listening:
                pulsingDot
                Text("Listening...")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            case .translating:
                Text("Translating...")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            case .synthesizing:
                Text("Preparing voice...")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            case .speaking:
                Text("Speaking...")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            case .error(let msg):
                Text(msg)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.red.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
    }

    private var pulsingDot: some View {
        Circle()
            .fill(.red)
            .frame(width: 12, height: 12)
            .modifier(PulseModifier())
    }

    // MARK: - Colors

    private var backgroundColor: Color {
        switch pipeline.state {
        case .idle: return Color(white: 0.08)
        case .listening: return Color(red: 0.1, green: 0.05, blue: 0.15)
        case .translating: return Color(red: 0.05, green: 0.08, blue: 0.15)
        case .synthesizing, .speaking: return Color(red: 0.05, green: 0.12, blue: 0.08)
        case .error: return Color(red: 0.15, green: 0.05, blue: 0.05)
        }
    }

    private var buttonColor: Color {
        switch pipeline.state {
        case .idle: return .blue.opacity(0.8)
        case .listening: return .red.opacity(0.9)
        case .translating: return .purple.opacity(0.8)
        case .synthesizing, .speaking: return .green.opacity(0.8)
        case .error: return .orange.opacity(0.8)
        }
    }

    private var buttonGlow: Color {
        buttonColor.opacity(0.4)
    }

    // MARK: - Helpers

    private func requestPermissionsAndStart() async {
        let authorized = await pipeline.stt.requestAuthorization()
        if authorized {
            pipeline.startListening()
        } else {
            pipeline.state = .error("Microphone or speech permission denied")
        }
    }

    private func hapticFeedback(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

// MARK: - Pulse Animation

struct PulseModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .opacity(isPulsing ? 0.5 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}
