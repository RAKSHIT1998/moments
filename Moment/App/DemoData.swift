#if DEBUG
import Foundation

/// DEBUG-only demo content, clearly labelled, run through the *real* pipeline so what you see is
/// what the engine actually does. Never shipped in Release builds.
@MainActor
enum DemoData {
    struct Item { var text: String; var source: SourceType; var daysAgo: Int; var hints: [String: String] = [:] }

    static let items: [Item] = [
        Item(text: "Sarah\n\nSarah: omg I really want these New Balance 530 so bad 😍\nSarah: the grey ones\nYou: haha noted\n10:32 PM", source: .screenshot, daysAgo: 23),
        Item(text: "Rahul\n\nRahul: Bro let's go Goa in December 😂\nYou: I'm in\nRahul: book flights early this time\n9:14 PM", source: .screenshot, daysAgo: 11),
        Item(text: "Rahul\n\nRahul: Remind me I'll send you that property guy's number\nYou: yes please\nDelivered", source: .screenshot, daysAgo: 2),
        Item(text: "Sarah mentioned Tosaka while we were talking about Japanese food. She really wants to try it.", source: .manual, daysAgo: 27),
        Item(text: "Sarah's birthday is September 22.", source: .manual, daysAgo: 40),
        Item(text: "I need to renew my passport, service the car, call uncle about the shop and book Bali.", source: .voice, daysAgo: 1),
        Item(text: "Rahul\n\nRahul: got the new car finally\nRahul: white one\nYou: 🔥\n8:02 PM", source: .screenshot, daysAgo: 5),
        Item(text: "Priya\n\nPriya: dinner at Toit on Friday at 8?\nYou: yes!\n6:40 PM", source: .screenshot, daysAgo: 0),
        Item(text: "My brother Arjun said he'd bring the camera for the Goa trip.", source: .manual, daysAgo: 9),
        Item(text: "https://www.newbalance.com/pd/530/MR530-33089.html", source: .link, daysAgo: 23)
    ]

    static func seed(into env: AppEnvironment) {
        Task { await seedAsync(into: env) }
    }

    static func seedAsync(into env: AppEnvironment) async {
        // Idempotent: a previous seed may have been interrupted (UI tests kill the app early).
        guard !env.settings.demoLoaded, !env.storage.fetchMemories(includeArchived: true, includeUnreviewed: true).contains(where: \.isDemo) else {
            env.settings.demoLoaded = true
            return
        }
        env.settings.demoLoaded = true
        for item in items {
            let createdAt = Calendar.current.date(byAdding: .day, value: -item.daysAgo, to: .now) ?? .now
            let input = CaptureInput(payload: .text(item.text), sourceType: item.source, sourceApp: item.source == .screenshot ? "Messages" : nil, createdAt: createdAt, hints: item.hints)
            do {
                let outcome = try await env.importer.run(input)
                for m in outcome.memories {
                    m.metadata["demo"] = "true"
                    m.reviewStatus = .saved
                    m.source?.typeRaw = item.source.rawValue
                }
            } catch {
                Log.app.error("Demo seed failed for an item: \(error.localizedDescription)")
            }
        }
        env.storage.save()
        await env.surface.refresh(scheduleNotifications: false)
    }

    static func remove(from env: AppEnvironment) async {
        for m in env.storage.fetchMemories(includeArchived: true, includeUnreviewed: true) where m.isDemo {
            await env.actions.delete(m)
        }
        for p in env.storage.fetchPeople() where p.memories.isEmpty { p.isDeleted = true }
        env.storage.save()
        env.settings.demoLoaded = false
        await env.surface.refresh(scheduleNotifications: false)
    }
}
#endif
