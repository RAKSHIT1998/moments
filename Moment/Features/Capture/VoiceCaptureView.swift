import SwiftUI

/// Tap Voice → recording starts immediately. A live waveform, the transcript as it forms,
/// then "Understanding…" and the found Moments.
struct VoiceCaptureView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onSubmit: (CaptureInput) -> Void
    let cancel: () -> Void
    @State private var levels: [Float] = Array(repeating: 0.05, count: 36)
    @State private var ticker: Task<Void, Never>?

    var body: some View {
        VStack(spacing: MSpacing.xl) {
            Spacer()
            switch env.speech.state {
            case .recording:
                Text("Listening").eyebrowStyle()
                Waveform(levels: levels)
                    .frame(height: 72)
                    .padding(.horizontal, MSpacing.xxl)
                    .accessibilityHidden(true)
                Text(env.speech.liveTranscript.isEmpty ? "Say what you want to remember." : env.speech.liveTranscript)
                    .font(env.speech.liveTranscript.isEmpty ? MFont.body : MFont.title)
                    .foregroundStyle(env.speech.liveTranscript.isEmpty ? MColor.textSecondary : MColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, MSpacing.xl)
                    .animation(reduceMotion ? nil : MAnimation.gentle, value: env.speech.liveTranscript)
                    .accessibilityIdentifier("voiceTranscript")
                if env.speech.usesOnDeviceRecognition {
                    Label("Transcribed on this iPhone", systemImage: "iphone").font(MFont.caption).foregroundStyle(MColor.textTertiary)
                }
            case .transcribing:
                ProgressView()
                Text("Understanding…").font(MFont.title).tracking(-0.3)
            case .failed(let message):
                Image(systemName: "mic.slash").font(.largeTitle).foregroundStyle(MColor.textSecondary)
                Text(message).font(MFont.body).multilineTextAlignment(.center).padding(.horizontal, MSpacing.xl).accessibilityIdentifier("voiceFailed")
            default:
                ProgressView()
            }
            Spacer()
            if env.speech.state == .recording {
                Button { Task { await stop() } } label: { Label("Done", systemImage: "stop.fill") }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal, MSpacing.xl)
                    .accessibilityIdentifier("voiceStop")
            } else if case .failed = env.speech.state {
                Button("Back") { cancel() }.buttonStyle(SecondaryButtonStyle()).padding(.horizontal, MSpacing.xl)
            }
        }
        .padding(.bottom, MSpacing.xl)
        .task { await start() }
        .onDisappear { ticker?.cancel(); if env.speech.state == .recording { env.speech.cancel() } }
    }

    private func start() async {
        guard await env.speech.requestPermissions() else { return }
        do { try env.speech.start() } catch { Log.capture.error("Voice start failed: \(error.localizedDescription)") }
        ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
                levels.removeFirst()
                levels.append(max(0.05, env.speech.audioLevel))
            }
        }
    }

    private func stop() async {
        ticker?.cancel()
        let transcript = await env.speech.stop()
        let audioURL = env.speech.recordedFileURL
        guard !transcript.isBlank else { env.speech.cancel(); cancel(); return }
        onSubmit(CaptureInput(payload: audioURL.map { .audio($0) } ?? .text(transcript), sourceType: .voice, extractedText: transcript, extractionConfidence: 0.85))
    }
}

/// Bars driven by recent audio levels. Cheap: one Canvas, no per-bar views.
struct Waveform: View {
    let levels: [Float]
    var body: some View {
        Canvas { ctx, size in
            let n = levels.count
            let gap: CGFloat = 3
            let w = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
            for (i, l) in levels.enumerated() {
                let h = max(4, CGFloat(l) * size.height)
                let rect = CGRect(x: CGFloat(i) * (w + gap), y: (size.height - h) / 2, width: w, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: w / 2), with: .color(Color.accentColor.opacity(0.35 + Double(l) * 0.65)))
            }
        }
    }
}
