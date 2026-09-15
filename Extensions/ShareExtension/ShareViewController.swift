import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// Receives images, text, URLs, PDFs and files from any app, drops them into the app-group inbox,
/// and gets out of the way. No AI here — the app understands them on next launch/foreground.
final class ShareViewController: UIViewController {
    private var host: UIHostingController<ShareConfirmationView>?
    private var status = ShareStatus()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let hosting = UIHostingController(rootView: ShareConfirmationView(status: status, done: { [weak self] in self?.finish() }))
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hosting.didMove(toParent: self)
        host = hosting
        Task { await ingest() }
    }

    private func ingest() async {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { status.fail("Nothing to share."); return }
        // NSItemProvider is thread-safe by contract but not marked Sendable; hand the array over explicitly.
        let providers = ProviderBox(items.flatMap { $0.attachments ?? [] })
        let sourceApp = Bundle.main.object(forInfoDictionaryKey: "NSExtensionHostBundleIdentifier") as? String
        let outcome = await ShareIngestor.ingest(providers, sourceApp: sourceApp)
        if outcome.count > 0 { status.succeed(outcome.count) } else { status.fail(outcome.failed ? "Couldn't read this item." : "Nothing MOMENT can read yet.") }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

struct ProviderBox: @unchecked Sendable { let providers: [NSItemProvider]; init(_ p: [NSItemProvider]) { providers = p } }

/// Runs off the main actor: reads each provider and drops it into the app-group inbox.
enum ShareIngestor {
    struct Outcome: Sendable { var count = 0; var failed = false }

    nonisolated static func ingest(_ box: ProviderBox, sourceApp: String?) async -> Outcome {
        var out = Outcome()
        for provider in box.providers {
            do { if try await ingest(provider, sourceApp: sourceApp) { out.count += 1 } }
            catch { out.failed = true }
        }
        return out
    }

    private static func ingest(_ provider: NSItemProvider, sourceApp: String?) async throws -> Bool {
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let data = try await loadData(provider, type: .image)
            try ShareInbox.enqueue(SharedCaptureItem(kind: .image, fileName: "\(UUID().uuidString).img", sourceApp: sourceApp), payload: data)
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            let data = try await loadData(provider, type: .pdf)
            try ShareInbox.enqueue(SharedCaptureItem(kind: .pdf, fileName: "\(UUID().uuidString).pdf", sourceApp: sourceApp), payload: data)
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try await loadItem(provider, type: .url) as? URL {
                if url.isFileURL {
                    let data = try Data(contentsOf: url)
                    try ShareInbox.enqueue(SharedCaptureItem(kind: url.pathExtension.lowercased() == "pdf" ? .pdf : .file, fileName: "\(UUID().uuidString).\(url.pathExtension)", sourceApp: sourceApp), payload: data)
                } else {
                    try ShareInbox.enqueue(SharedCaptureItem(kind: .url, text: url.absoluteString, sourceApp: sourceApp))
                }
                return true
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try await loadItem(provider, type: .plainText) as? String, !text.isEmpty {
                try ShareInbox.enqueue(SharedCaptureItem(kind: .text, text: text, sourceApp: sourceApp))
                return true
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
            let data = try await loadData(provider, type: .data)
            try ShareInbox.enqueue(SharedCaptureItem(kind: .file, fileName: "\(UUID().uuidString).bin", sourceApp: sourceApp), payload: data)
            return true
        }
        return false
    }

    private static func loadData(_ provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? NSError(domain: "Moment.Share", code: 1)) }
            }
        }
    }

    /// `loadItem` is completion-based underneath; wrapping it keeps the call off the main actor.
    private static func loadItem(_ provider: NSItemProvider, type: UTType) async throws -> (any NSSecureCoding)? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: item) }
            }
        }
    }
}

@Observable
final class ShareStatus {
    var message = ""
    var isDone = false
    var succeeded = false
    func succeed(_ count: Int) { message = count == 1 ? "Saved to MOMENT." : "Saved \(count) items to MOMENT."; succeeded = true; isDone = true }
    func fail(_ m: String) { message = m; succeeded = false; isDone = true }
}

struct ShareConfirmationView: View {
    var status: ShareStatus
    let done: () -> Void
    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 14) {
                if status.isDone {
                    Image(systemName: status.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle").font(.system(size: 36)).foregroundStyle(status.succeeded ? Color.green : Color.orange)
                    Text(status.message).font(.headline).multilineTextAlignment(.center)
                    if status.succeeded { Text("MOMENT will understand it the next time you open the app.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                    Button("Done", action: done).buttonStyle(.borderedProminent)
                } else {
                    ProgressView()
                    Text("Sending to MOMENT…").font(.headline)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding()
            Spacer()
        }
        .background(Color.black.opacity(0.25).ignoresSafeArea())
        .task {
            // Auto-dismiss on success so sharing feels instant.
            try? await Task.sleep(for: .seconds(1.4))
            if status.succeeded { done() }
        }
    }
}
