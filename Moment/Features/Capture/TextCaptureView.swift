import SwiftUI

struct TextCaptureView: View {
    enum Kind { case text, link }
    let kind: Kind
    let onSubmit: (CaptureInput) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.l) {
            Text(kind == .text ? "What do you want to remember?" : "Paste a link").font(MFont.title)
            if kind == .text {
                TextEditor(text: $text)
                    .font(MFont.body)
                    .scrollContentBackground(.hidden)
                    .padding(MSpacing.m)
                    .frame(minHeight: 180)
                    .background(MColor.surface, in: RoundedRectangle(cornerRadius: MSpacing.cardRadius, style: .continuous))
                    .focused($focused)
                    .accessibilityLabel("Moment text")
                    .accessibilityIdentifier("captureTextEditor")
                Text("Try: “Sarah wants to try Tosaka” or “Remind me to call Rahul tomorrow about the property.”")
                    .font(MFont.footnote).foregroundStyle(MColor.textSecondary)
            } else {
                TextField("https://", text: $text)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .padding(MSpacing.m)
                    .background(MColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .focused($focused)
                    .accessibilityIdentifier("captureLinkField")
            }
            Spacer()
            Button("Save Moment") { submit() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!isValid)
                .accessibilityIdentifier("captureSubmit")
        }
        .padding(MSpacing.l)
        .onAppear { focused = true }
    }

    private var isValid: Bool {
        switch kind {
        case .text: !text.isBlank
        case .link: URL(string: text.trimmed)?.scheme?.hasPrefix("http") == true
        }
    }

    private func submit() {
        switch kind {
        case .text: onSubmit(CaptureInput(payload: .text(text.trimmed), sourceType: .manual))
        case .link: if let url = URL(string: text.trimmed) { onSubmit(CaptureInput(payload: .url(url), sourceType: .link)) }
        }
    }
}
