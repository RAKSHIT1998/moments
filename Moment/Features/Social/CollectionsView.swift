import SwiftUI

/// Albums of Moments. Private to you; a way to keep "Goa trips" or "2026" together.
struct CollectionsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showNew = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MSpacing.l) {
                if env.social.collections.isEmpty {
                    VStack(alignment: .leading, spacing: MSpacing.s) {
                        Text("No collections yet.").font(MFont.title)
                        Text("Group Moments into albums — a trip, a year, a person. Only you see them.").font(MFont.body).foregroundStyle(MColor.textSecondary)
                        Button { showNew = true } label: { Text("New collection").frame(maxWidth: .infinity) }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("newCollectionEmpty")
                    }
                    .momentCard()
                }
                ForEach(env.social.collections) { c in
                    NavigationLink(value: SocialRoute.collection(c.id)) { CollectionCard(collection: c) }.buttonStyle(PressScaleStyle())
                }
            }
            .padding(MSpacing.l).padding(.bottom, 80)
        }
        .background(MColor.background)
        .navigationTitle("Collections")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showNew = true } label: { Image(systemName: "plus") }.accessibilityLabel("New collection").accessibilityIdentifier("newCollection") } }
        .sheet(isPresented: $showNew) { CollectionEditorSheet() }
        .task { await env.social.refreshCollections() }
    }
}

struct CollectionCard: View {
    @Environment(AppEnvironment.self) private var env
    let collection: MomentCollection
    var body: some View {
        let ms = env.social.moments(in: collection)
        HStack(spacing: MSpacing.m) {
            ZStack {
                RoundedRectangle(cornerRadius: MRadius.tile, style: .continuous).fill(MColor.accentSoft).frame(width: 84, height: 84)
                if let first = ms.first { SocialImage(ref: first.coverRef).frame(width: 84, height: 84).clipShape(RoundedRectangle(cornerRadius: MRadius.tile, style: .continuous)) }
                Text(collection.emoji).font(.title).shadow(radius: 4)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(collection.title).font(MFont.headline).foregroundStyle(MColor.textPrimary)
                Text("\(collection.momentIDs.count) \(collection.momentIDs.count == 1 ? "Moment" : "Moments")\(ms.first.map { " · latest \($0.dateLabel)" } ?? "")").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                if !ms.isEmpty { AvatarStack(names: Array(Set(ms.flatMap(\.memberNames))).sorted(), size: 22) }
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(MColor.textTertiary)
        }
        .momentCard()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("collection-\(collection.id)")
    }
}

struct CollectionDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let collectionID: String
    @State private var showEdit = false
    @State private var confirmDelete = false

    private var collection: MomentCollection? { env.social.collections.first { $0.id == collectionID } }

    var body: some View {
        ScrollView {
            if let c = collection {
                let ms = env.social.moments(in: c)
                VStack(alignment: .leading, spacing: MSpacing.l) {
                    HStack(alignment: .firstTextBaseline, spacing: MSpacing.s) {
                        Text(c.emoji).font(.largeTitle)
                        Text(c.title).displayStyle()
                    }
                    HStack(spacing: MSpacing.s) {
                        StatTile(value: "\(ms.count)", label: "Moments")
                        StatTile(value: "\(Set(ms.flatMap(\.memberIDs)).subtracting([env.social.myID]).count)", label: "People")
                        StatTile(value: "\(ms.reduce(0) { $0 + $1.mediaCount })", label: "Photos")
                    }
                    if ms.isEmpty { Text("Add Moments from any Moment's menu → \"Add to collection\".").font(MFont.footnote).foregroundStyle(MColor.textSecondary) }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: MSpacing.s), GridItem(.flexible(), spacing: MSpacing.s)], spacing: MSpacing.s) {
                        ForEach(ms) { m in
                            NavigationLink(value: SocialRoute.moment(m.id)) { MomentTile(moment: m) }.buttonStyle(PressScaleStyle())
                                .contextMenu { Button("Remove from collection", systemImage: "minus.circle", role: .destructive) { Task { await env.social.toggle(momentID: m.id, in: c.id) } } }
                        }
                    }
                }
                .padding(MSpacing.l).padding(.bottom, 80)
            }
        }
        .background(MColor.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Rename", systemImage: "pencil") { showEdit = true }
                    Button("Delete collection", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showEdit) { if let c = collection { CollectionEditorSheet(existing: c) } }
        .confirmationDialog("Delete this collection?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await env.social.deleteCollection(collectionID); dismiss() } }
        } message: { Text("The Moments inside stay where they are.") }
    }
}

struct CollectionEditorSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    var existing: MomentCollection? = nil
    var initialMomentID: String? = nil
    @State private var title = ""
    @State private var emoji = "📁"
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: MSpacing.l) {
                TextField("Goa trips, 2026, Birthdays…", text: $title).font(.title2.weight(.semibold)).focused($focused).accessibilityIdentifier("collectionTitle")
                EmojiRow(selection: $emoji)
                Text("Collections are private. Only you see how you group your Moments.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                Spacer()
            }
            .padding(MSpacing.l)
            .navigationTitle(existing == nil ? "New collection" : "Rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Create" : "Save") {
                        Task {
                            if let existing { await env.social.rename(collectionID: existing.id, title: title, emoji: emoji) }
                            else { _ = await env.social.createCollection(title: title, emoji: emoji, momentIDs: initialMomentID.map { [$0] } ?? []) }
                            Haptics.saved(); dismiss()
                        }
                    }.disabled(title.isBlank).accessibilityIdentifier("saveCollection")
                }
            }
            .onAppear { if let existing { title = existing.title; emoji = existing.emoji }; focused = true }
        }
        .presentationDetents([.medium])
    }
}

/// From a Moment's menu: tick the collections it belongs to.
struct AddToCollectionSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let momentID: String
    @State private var showNew = false
    var body: some View {
        NavigationStack {
            List {
                ForEach(env.social.collections) { c in
                    Button { Task { await env.social.toggle(momentID: momentID, in: c.id); Haptics.selection() } } label: {
                        HStack { Text(c.emoji); Text(c.title).foregroundStyle(MColor.textPrimary); Spacer(); if c.momentIDs.contains(momentID) { Image(systemName: "checkmark.circle.fill").foregroundStyle(MColor.accent) } }
                    }
                    .accessibilityIdentifier("addTo-\(c.id)")
                }
                Button { showNew = true } label: { Label("New collection", systemImage: "plus") }
            }
            .navigationTitle("Add to collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showNew) { CollectionEditorSheet(initialMomentID: momentID) }
        }
        .presentationDetents([.medium, .large])
    }
}

/// "Your 2026 in Moments" — real counts, shown on the profile once there's something to show.
struct YearCard: View {
    let summary: SocialService.YearSummary
    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            HStack {
                Text("YOUR \(String(summary.year)) IN MOMENTS").font(MFont.eyebrow).tracking(1).foregroundStyle(.white.opacity(0.85))
                Spacer()
                Image(systemName: "sparkles").foregroundStyle(.white.opacity(0.85))
            }
            HStack(spacing: MSpacing.l) {
                big("\(summary.moments)", "Moments"); big("\(summary.people)", "people"); big("\(summary.places)", "places")
            }
            VStack(alignment: .leading, spacing: 4) {
                if let p = summary.topPerson { line("Most often with", p) }
                if let p = summary.topPlace { line("Most often in", p) }
                if let m = summary.busiestMonth { line("Busiest month", m) }
            }
        }
        .padding(MSpacing.l)
        .background(MColor.accentGradient, in: RoundedRectangle(cornerRadius: MRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: MRadius.card, style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
        .shadow(color: MShadow.accent.color, radius: MShadow.accent.radius, y: MShadow.accent.y)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("yearCard")
    }
    private func big(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 0) { Text(v).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.white); Text(l).font(MFont.caption).foregroundStyle(.white.opacity(0.85)) }
    }
    private func line(_ k: String, _ v: String) -> some View {
        HStack(spacing: 6) { Text(k).font(MFont.footnote).foregroundStyle(.white.opacity(0.8)); Text(v).font(.footnote.weight(.semibold)).foregroundStyle(.white) }
    }
}
