import Foundation

/// A Moment template: which slides, in which order, with which look. Built-in templates ship
/// with the app; received `.moment` packages carry the template they were made with so a
/// recipient can "make their own" from the same structure.
struct MomentTemplate: Codable, Identifiable, Sendable, Equatable, Hashable {
    enum Style: String, Codable, CaseIterable, Sendable {
        case minimal, cinematic, polaroid, chat, timeline, people, trip, funny, emotional, stats, quote
        var label: String {
            switch self {
            case .minimal: "Minimal"; case .cinematic: "Cinematic"; case .polaroid: "Polaroid"; case .chat: "Chat"
            case .timeline: "Timeline"; case .people: "People"; case .trip: "Trip"; case .funny: "Funny"
            case .emotional: "Emotional"; case .stats: "Stats"; case .quote: "Quote"
            }
        }
    }

    /// What each slide should draw from.
    enum Section: String, Codable, Sendable {
        case cover, bestPhotos, quotes, jokes, people, places, plansSaid, plansDone, promisesKept, timeline, stats, closing, mostPhotographedDay, unfinishedPlan, newPeople
    }

    var id: String
    var name: String
    var emoji: String
    var style: Style
    var sections: [Section]
    /// Optional fixed title pattern. `{year}`, `{month}`, `{place}`, `{person}` are substituted.
    var titlePattern: String?
    var creditedTo: String?

    static let builtIn: [MomentTemplate] = [
        MomentTemplate(id: "drop.trip", name: "Our trip", emoji: "✈️", style: .trip, sections: [.cover, .bestPhotos, .places, .people, .quotes, .jokes, .timeline, .stats, .closing], titlePattern: "{place}"),
        MomentTemplate(id: "drop.night", name: "That night", emoji: "🌙", style: .cinematic, sections: [.cover, .bestPhotos, .quotes, .jokes, .people, .closing], titlePattern: nil),
        MomentTemplate(id: "year.sofar", name: "My {year} so far", emoji: "🔥", style: .stats, sections: [.cover, .stats, .bestPhotos, .people, .places, .plansSaid, .plansDone, .quotes, .closing], titlePattern: "My {year} so far"),
        MomentTemplate(id: "year.full", name: "Year in Moments", emoji: "🎞️", style: .cinematic, sections: [.cover, .stats, .bestPhotos, .people, .places, .promisesKept, .plansDone, .unfinishedPlan, .quotes, .closing], titlePattern: "Your {year}"),
        MomentTemplate(id: "month.recap", name: "Month in Moments", emoji: "📅", style: .stats, sections: [.cover, .stats, .bestPhotos, .people, .places, .plansSaid, .unfinishedPlan, .quotes, .closing], titlePattern: "{month}"),
        MomentTemplate(id: "people.mine", name: "My people", emoji: "🫶", style: .people, sections: [.cover, .people, .bestPhotos, .quotes, .closing], titlePattern: "My people"),
        MomentTemplate(id: "said.would", name: "Things I said I'd do", emoji: "😂", style: .funny, sections: [.cover, .plansSaid, .plansDone, .unfinishedPlan, .closing], titlePattern: "Things I said I'd do"),
        MomentTemplate(id: "friendship", name: "Me & {person}", emoji: "❤️", style: .people, sections: [.cover, .stats, .timeline, .bestPhotos, .quotes, .jokes, .plansSaid, .closing], titlePattern: "Me & {person}"),
        MomentTemplate(id: "quotes.best", name: "Best things we said", emoji: "💬", style: .chat, sections: [.cover, .quotes, .jokes, .closing], titlePattern: "Things we actually said"),
        MomentTemplate(id: "polaroid", name: "Polaroids", emoji: "📸", style: .polaroid, sections: [.cover, .bestPhotos, .closing], titlePattern: nil),
        MomentTemplate(id: "places", name: "Places we've been", emoji: "📍", style: .trip, sections: [.cover, .places, .bestPhotos, .closing], titlePattern: "Places we've been"),
        MomentTemplate(id: "emotional", name: "Never forget", emoji: "😭", style: .emotional, sections: [.cover, .bestPhotos, .quotes, .closing], titlePattern: nil)
    ]

    static func find(_ id: String) -> MomentTemplate? { builtIn.first { $0.id == id } }

    func resolvedTitle(year: Int, month: String?, place: String?, person: String?, fallback: String) -> String {
        guard let pattern = titlePattern else { return fallback }
        var t = pattern.replacingOccurrences(of: "{year}", with: String(year))
        t = t.replacingOccurrences(of: "{month}", with: month ?? fallback)
        t = t.replacingOccurrences(of: "{place}", with: place ?? fallback)
        t = t.replacingOccurrences(of: "{person}", with: person ?? fallback)
        return t
    }
}
