import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// "+ MOMENT". No categories to pick — the AI decides. Every path leads to `CaptureResultView`.
struct CaptureSheet: View {
    enum Phase: Equatable {
        case choose, text, voice, link, processing(ImportService.Stage), result, failed(String)
    }

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .choose
    @State private var outcome: ImportService.Outcome?
    @State private var lastInput: CaptureInput?
    @State private var photoItem: PhotosPickerItem?
    @State private var showScanner = false
    @State private var showFileImporter = false
    @State private var showPaywall = false
    @State private var showShareHelp = false
    @State private var showDrop = false
    @State private var dropEditor: UUID?

    var initialInput: CaptureInput?

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .choose: chooser
                case .text: TextCaptureView(kind: .text) { run($0) }
                case .link: TextCaptureView(kind: .link) { run($0) }
                case .voice: VoiceCaptureView { run($0) } cancel: { phase = .choose }
                case .processing(let stage): processing(stage)
                case .result:
                    if let outcome { CaptureResultView(outcome: outcome, onDone: { dismiss() }) }
                case .failed(let message): failed(message)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .processing = phase { EmptyView() } else if phase != .result {
                        Button("Cancel") { cancel() }
                    }
                }
            }
            .background(AmbientBackdrop(intensity: 0.7).ignoresSafeArea())
        }
        .interactiveDismissDisabled({ if case .processing = phase { true } else { false } }())
        .presentationDetents(phase == .choose ? [.large] : [.large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showScanner) { DocumentScannerView { images in if let first = images.first, let data = first.jpegData(compressionQuality: 0.9) { run(CaptureInput(payload: .image(data), sourceType: .scan)) } } }
        .sheet(isPresented: $showPaywall) { PaywallView(presentedAsSheet: true) }
        .sheet(isPresented: $showShareHelp) { ShareHelpView() }
        .sheet(isPresented: $showDrop) {
            NavigationStack {
                if let id = dropEditor { MomentEditorView(storyID: id).momentDestinations() }
                else { MemoryDropView { id in dropEditor = id }.toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showDrop = false } } } }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.pdf, .image, .plainText, .text], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // Copy into our sandbox so the pipeline can read it after the scope closes.
            let tmp = FileManager.default.temporaryDirectory.appending(path: url.lastPathComponent)
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.copyItem(at: url, to: tmp)
            if url.pathExtension.lowercased() == "pdf" { run(CaptureInput(payload: .pdf(tmp), sourceType: .pdf)) }
            else { run(CaptureInput(payload: .file(tmp), sourceType: .shareSheet)) }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    run(CaptureInput(payload: .image(data), sourceType: .photo))
                }
                photoItem = nil
            }
        }
        .task {
            if let initialInput { run(initialInput) }
        }
    }

    // MARK: Chooser

    private var chooser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MSpacing.l) {
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text("What should I remember?").displayStyle()
                    Text("No categories. Just give it to me.").font(MFont.body).foregroundStyle(MColor.textSecondary)
                }
                .padding(.top, MSpacing.s)

                if let preview = clipboardPreview {
                    Button { pasteClipboard() } label: {
                        optionRow("Paste what you copied", preview, "doc.on.clipboard", highlighted: true)
                    }.buttonStyle(PressScaleStyle()).accessibilityIdentifier("captureClipboard")
                }

                VStack(spacing: MSpacing.s) {
                    option("Voice", "Say it. I'll pick out what matters.", "waveform", id: "captureVoice") { phase = .voice }
                    option("Text", "Write it down.", "keyboard", id: "captureText") { phase = .text }
                    PhotosPicker(selection: $photoItem, matching: .images) { optionRow("Screenshot or photo", "Chats, receipts, anything with words.", "photo.on.rectangle") }
                        .buttonStyle(PressScaleStyle()).accessibilityIdentifier("capturePhoto")
                    option("Camera", "Scan a page, a screen, a note.", "camera", id: "captureScan") { showScanner = true }
                    option("Link", "Save a webpage.", "link", id: "captureLink") { phase = .link }
                    option("File", "PDF or document.", "doc.text", id: "capturePDF") { showFileImporter = true }
                    option("Memory Drop", "Many photos → one story to share.", "photo.stack", id: "captureDrop") { showDrop = true }
                }
                Button { showShareHelp = true } label: {
                    Label("Or share to MOMENT from any app", systemImage: "square.and.arrow.up").font(MFont.subheadline)
                }
                .padding(.top, MSpacing.xs)
                .accessibilityIdentifier("captureShare")
            }
            .padding(.horizontal, MSpacing.l)
            .padding(.vertical, MSpacing.l)
        }
    }

    /// Only offered when the clipboard actually has something we can use.
    private var clipboardPreview: String? {
        let board = UIPasteboard.general
        if board.hasImages { return "An image" }
        if board.hasURLs, let u = board.url { return u.host() ?? u.absoluteString }
        if board.hasStrings, let s = board.string, !s.isBlank { return s.truncated(60) }
        return nil
    }

    private func option(_ title: String, _ subtitle: String, _ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { optionRow(title, subtitle, symbol) }
            .buttonStyle(PressScaleStyle())
            .accessibilityIdentifier(id)
    }

    private func optionRow(_ title: String, _ subtitle: String, _ symbol: String, highlighted: Bool = false) -> some View {
        HStack(spacing: MSpacing.m) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(highlighted ? Color.white : MColor.accent)
                .frame(width: MIcon.tile, height: MIcon.tile)
                .background {
                    if highlighted { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MColor.accentGradient) }
                    else { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MColor.accentSoft) }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(MFont.headline).foregroundStyle(MColor.textPrimary)
                Text(subtitle).font(MFont.subheadline).foregroundStyle(MColor.textSecondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(MColor.textTertiary)
        }
        .frame(minHeight: MTouch.minimum)
        .momentCard(padding: MSpacing.m)
        .contentShape(Rectangle())
    }

    private func pasteClipboard() {
        let board = UIPasteboard.general
        if let image = board.image, let data = image.jpegData(compressionQuality: 0.9) {
            run(CaptureInput(payload: .image(data), sourceType: .clipboard))
        } else if let url = board.url {
            run(CaptureInput(payload: .url(url), sourceType: .clipboard))
        } else if let text = board.string, !text.isBlank {
            if let url = URL(string: text.trimmed), url.scheme?.hasPrefix("http") == true, !text.contains(" ") {
                run(CaptureInput(payload: .url(url), sourceType: .clipboard))
            } else {
                run(CaptureInput(payload: .clipboard(text), sourceType: .clipboard))
            }
        } else {
            phase = .failed("Nothing on the clipboard to remember.")
        }
    }

    // MARK: Processing

    private func processing(_ stage: ImportService.Stage) -> some View {
        VStack(alignment: .leading, spacing: MSpacing.xl) {
            Spacer()
            ProcessingStepsView(steps: ["Reading…", "Understanding…", "Connecting context…", "Remembering…"], currentIndex: stage.rawValue)
                .padding(.horizontal, MSpacing.xl)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("captureProcessing")
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: MSpacing.l) {
            Spacer()
            Image(systemName: "questionmark.circle").font(.system(size: 40)).foregroundStyle(MColor.textSecondary)
            Text("I couldn't understand that.").font(MFont.title).tracking(-0.3)
            Text(message).font(MFont.body).foregroundStyle(MColor.textSecondary).multilineTextAlignment(.center)
            Spacer()
            VStack(spacing: MSpacing.m) {
                if let lastInput {
                    Button("Try again") { run(lastInput) }.buttonStyle(PrimaryButtonStyle())
                    Text("Try again or save the original.").font(MFont.footnote).foregroundStyle(MColor.textTertiary)
                    if !lastInput.textForAnalysis.isBlank || lastInput.isImage {
                        Button("Save anyway") { saveOriginal(lastInput) }.buttonStyle(SecondaryButtonStyle())
                    }
                }
                Button("Cancel") { cancel() }.buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(MSpacing.xl)
    }

    // MARK: Actions

    private func run(_ input: CaptureInput) {
        guard env.subscriptions.canCreateMemory(currentCount: env.storage.memoryCount) else { showPaywall = true; return }
        lastInput = input
        phase = .processing(.analyzing)
        Task {
            do {
                let outcome = try await env.importer.run(input) { stage in phase = .processing(stage) }
                self.outcome = outcome
                Haptics.captureCompleted()
                phase = .result
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Understanding failed but the user still wants to keep it: store the raw content honestly.
    private func saveOriginal(_ input: CaptureInput) {
        Task {
            let text = input.textForAnalysis
            let fallback = AnalysisResult(memories: [ExtractedMemory(title: text.isBlank ? "Saved \(input.sourceType.label.lowercased())" : text.truncated(70), summary: "Saved as captured. MOMENT couldn't understand it yet.", content: text, memoryType: input.isImage ? .photo : .reference, confidence: 0.3, evidence: text)], confidence: 0.3, normalizedText: text)
            if let memories = try? await env.importer.persist(fallback, input: input, processedBy: "none") {
                env.actions.saveAll(memories)
                dismiss()
            }
        }
    }

    private func cancel() {
        env.speech.cancel()
        dismiss()
    }
}

/// Explains the Share Sheet path once; the extension does the rest.
struct ShareHelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: MSpacing.xl) {
                Text("Share anything to MOMENT").font(MFont.title)
                VStack(alignment: .leading, spacing: MSpacing.m) {
                    step(1, "Take a screenshot, or open a link, photo, or PDF.")
                    step(2, "Tap Share.")
                    step(3, "Choose MOMENT. You don't need to open the app first.")
                }
                Text("It lands in your Inbox, already understood.").font(MFont.body).foregroundStyle(MColor.textSecondary)
                Spacer()
            }
            .padding(MSpacing.xl)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: MSpacing.m) {
            Text("\(n)").font(.headline).frame(width: 28, height: 28).background(MColor.fill, in: Circle())
            Text(text).font(MFont.body)
        }
    }
}
