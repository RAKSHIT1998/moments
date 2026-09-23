import SwiftUI

/// Where your Moments go. Decentralised by default: phone-to-phone mesh plus relays you choose.
struct NetworkSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var newRelay = ""
    @State private var stats: (peers: Int, relays: Int, events: Int) = (0, 0, 0)

    var body: some View {
        @Bindable var settings = env.settings
        List {
            Section {
                Picker("Network", selection: Binding(get: { settings.networkMode }, set: { m in Task { await env.setNetworkMode(m) } })) {
                    ForEach(NetworkMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(settings.networkMode.explanation).font(MFont.footnote).foregroundStyle(MColor.textSecondary)
            }
            if settings.networkMode == .mesh {
                Section("Right now") {
                    row("Nearby phones", "\(stats.peers)", "Synced directly over Wi‑Fi and Bluetooth. No internet needed.")
                    row("Relays connected", "\(stats.relays) of \(settings.relayURLs.count)")
                    row("Events on this phone", "\(stats.events)", "Every signed record you've seen — yours and your friends'.")
                }
                Section {
                    Toggle(isOn: Binding(get: { settings.meshEnabled }, set: { settings.meshEnabled = $0; Task { await env.reloadRelays() } })) { Label("Phone‑to‑phone", systemImage: "iphone.radiowaves.left.and.right") }
                } footer: { Text("When on, people in the same room get your posts instantly — even offline. Others only ever see signed events, never your identity beyond your MOMENT ID.") }
                Section {
                    ForEach(settings.relayURLs, id: \.self) { url in
                        HStack { Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(MColor.textSecondary); Text(url).font(MFont.body.monospaced()).lineLimit(1).truncationMode(.middle) }
                    }
                    .onDelete { idx in settings.relayURLs.remove(atOffsets: idx); Task { await env.reloadRelays() } }
                    HStack {
                        TextField("wss://relay.example.org", text: $newRelay).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        Button("Add") { add() }.disabled(!isValid(newRelay))
                    }
                } header: { Text("Relays") } footer: {
                    Text("Relays are open servers anyone can run — a friend, a café, you. They store signed events and can't read private Moments. Add several; the app dedupes. Run your own with the `relay/` folder in the source.")
                }
            }
        }
        .navigationTitle("Network")
        .task { await refresh() }
    }

    private func row(_ title: String, _ value: String, _ note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text(value).foregroundStyle(MColor.textSecondary).monospacedDigit() }
            if let note { Text(note).font(MFont.footnote).foregroundStyle(MColor.textSecondary) }
        }
    }
    private func isValid(_ s: String) -> Bool { guard let u = URL(string: s.trimmed), let sch = u.scheme?.lowercased(), sch == "ws" || sch == "wss", u.host() != nil else { return false }; return true }
    private func add() {
        let s = newRelay.trimmed; guard isValid(s), !env.settings.relayURLs.contains(s) else { return }
        env.settings.relayURLs.append(s); newRelay = ""
        Task { await env.reloadRelays(); await refresh() }
    }
    private func refresh() async {
        guard let b = env.social.backend as? DecentralizedBackend else { return }
        stats = (await b.peerCount(), await b.relayCount(), await b.eventCount())
    }
}
