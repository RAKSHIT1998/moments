import SwiftUI

/// "Ask your memory anything." Answer first, then sources with reasons. The field also takes
/// commands ("Remember that…", "Remind me to…", "Who owes me something?").
struct SearchView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var path = NavigationPath()
    @State private var query = ""
    @State private var result: SearchResult?
    @State private var hits: [Memory] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var pendingCommand: CommandRouter.Command?
    @State private var whyHit: (SearchResult.Hit, Memory)?
    @State private var showWhy = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: MSpacing.l) {
                    hero
                    field
                    if query.isBlank { suggestions } else { results }
                }
                .padding(MSpacing.l)
            }
            .background(AmbientBackdrop(intensity: 0.7).ignoresSafeArea())
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(.hidden, for: .navigationBar)
            .momentDestinations()
            .withCaptureButton()
            .sheet(isPresented: $showWhy) {
                if let (hit, m) = whyHit {
                    WhySheet(title: m.title, explanation: "I found this in your \(m.sourceType.label.lowercased()) from \(m.createdAt.mediumDate). \(hit.reason.isEmpty ? "" : "It matched because it \(hit.reason.lowercased()).")", source: (m.sourceType, m.createdAt))
                }
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: MSpacing.s) {
            Text("Search").eyebrowStyle().padding(.top, MSpacing.m)
            Text("Ask your memory anything.").displayStyle().accessibilityAddTraits(.isHeader)
        }
    }

    private var field: some View {
        HStack(spacing: MSpacing.m) {
            Image(systemName: "magnifyingglass").foregroundStyle(MColor.textSecondary)
            TextField("What are you trying to remember?", text: $query)
                .focused($focused)
                .submitLabel(.search)
                .onSubmit { submit() }
                .accessibilityIdentifier("searchField")
            if !query.isEmpty {
                Button { query = ""; result = nil; hits = [] } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(MColor.textTertiary) }
                    .accessibilityLabel("Clear")
            }
        }
        .padding(MSpacing.m)
        .frame(minHeight: 52)
        .background(MColor.surface, in: RoundedRectangle(cornerRadius: MRadius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: MRadius.control, style: .continuous).strokeBorder(focused ? MColor.accent.opacity(0.6) : MColor.separator.opacity(0.3), lineWidth: 1))
        .onChange(of: query) { _, _ in runSearch(immediate: false) }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            Text("Try asking").eyebrowStyle()
            ForEach(env.search.suggestions()) { s in
                Button { query = s.text; submit() } label: {
                    HStack(spacing: MSpacing.m) {
                        Image(systemName: s.symbol).foregroundStyle(MColor.accent).frame(width: 22)
                        Text(s.text).font(MFont.body).foregroundStyle(MColor.textPrimary).multilineTextAlignment(.leading)
                        Spacer()
                    }
                    .frame(minHeight: MTouch.minimum)
                }
                .buttonStyle(.plain)
            }
            Text("You can also tell me things: “Remember that Rahul likes Japanese food.”").font(MFont.footnote).foregroundStyle(MColor.textTertiary).padding(.top, MSpacing.s)
            if !env.settings.recentSearches.isEmpty {
                Button("Clear search history") { env.settings.clearSearchHistory() }.font(MFont.footnote).foregroundStyle(MColor.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        if let cmd = pendingCommand, case .capture(let text) = cmd {
            VStack(alignment: .leading, spacing: MSpacing.m) {
                Text("Sounds like something to remember").eyebrowStyle()
                Text("“\(text)”").font(MFont.headline)
                Button("Save as a Moment") { env.pendingCaptureInput = CaptureInput(payload: .text(text), sourceType: .manual); env.showCapture = true; query = "" }.buttonStyle(ChipButtonStyle(prominent: true))
            }.momentCard()
        }
        if let cmd = pendingCommand, case .tell(let subject) = cmd {
            let told = env.stories.tell(about: subject)
            if !told.lines.isEmpty {
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text("The story").eyebrowStyle()
                    ForEach(told.lines, id: \.self) { Text($0).font(MFont.body) }
                    Text("From \(told.memories.count) memor\(told.memories.count == 1 ? "y" : "ies") on this iPhone").font(MFont.caption).foregroundStyle(MColor.textTertiary)
                    if told.memories.count >= 2 {
                        Button("Make this a Moment") {
                            if let t = MomentTemplate.find("drop.trip"), let s = env.stories.create(kind: .collection, template: t, memories: told.memories, fallbackTitle: subject.capitalizedFirst) { path.append(Route.momentEditor(s.id)) }
                        }.buttonStyle(ChipButtonStyle(prominent: true))
                    }
                }.momentCard()
            }
        }
        if isSearching && result == nil { ProgressView().frame(maxWidth: .infinity) }
        if let r = result {
            if let answer = r.answer {
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text("Answer").eyebrowStyle()
                    Text(answer).font(MFont.title).tracking(-0.3).accessibilityIdentifier("searchAnswer")
                    Text("From \(hits.count) memor\(hits.count == 1 ? "y" : "ies") on this iPhone").font(MFont.caption).foregroundStyle(MColor.textTertiary)
                }
                .momentCard()
            }
            if r.interpretedIntent == .whatDoIKnowAbout, let name = r.peopleNames.first, let p = env.storage.fetchPeople().first(where: { $0.allNames.contains(name.lowercased()) }) {
                NavigationLink(value: Route.person(p.id)) {
                    HStack { PersonAvatar(name: p.displayName, size: 36); Text("Everything about \(p.displayName)").font(MFont.headline); Spacer(); Image(systemName: "chevron.right").font(.caption) }.momentCard(padding: MSpacing.m)
                }.buttonStyle(.plain)
            }
            if hits.isEmpty {
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text("I don't have that yet.").font(MFont.headline)
                    Text("I only answer from what you've given me. Try a person's name, a place, or a topic — or tell me something to remember.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                }.momentCard()
            } else {
                Text("Sources").eyebrowStyle()
                ForEach(Array(zip(r.hits, hits)), id: \.1.id) { hit, m in
                    VStack(alignment: .leading, spacing: MSpacing.s) {
                        NavigationLink(value: Route.memory(m.id)) { MomentCard(memory: m, compact: true) }.buttonStyle(.plain)
                        HStack {
                            Text(hit.reason).font(MFont.caption).foregroundStyle(MColor.accent)
                            Spacer()
                            Button { whyHit = (hit, m); showWhy = true } label: { Text("Why?").font(MFont.caption.weight(.semibold)) }
                                .accessibilityLabel("Why am I seeing this?")
                        }
                        .padding(.horizontal, MSpacing.s)
                    }
                }
            }
        }
    }

    private func submit() {
        let cmd = CommandRouter.route(query)
        switch cmd {
        case .promises: path.append(Route.promises); return
        case .gifts: path.append(Route.gifts); return
        case .plans: path.append(Route.plans); return
        case .person(let name):
            if let p = env.storage.fetchPeople().first(where: { $0.allNames.contains(name.lowercased()) }) { path.append(Route.person(p.id)); return }
        case .capture, .tell: pendingCommand = cmd
        case .search: pendingCommand = nil
        }
        runSearch(immediate: true)
    }

    private func runSearch(immediate: Bool) {
        searchTask?.cancel()
        let q = query.trimmed
        guard !q.isEmpty else { result = nil; hits = []; pendingCommand = nil; return }
        switch CommandRouter.route(q) {
        case .capture(let t): pendingCommand = .capture(t)
        case .tell(let s): pendingCommand = .tell(s)
        default: pendingCommand = nil
        }
        searchTask = Task {
            if !immediate { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            isSearching = true
            let (r, h) = await env.search.search(q)
            guard !Task.isCancelled else { return }
            result = r; hits = h; isSearching = false
        }
    }
}
