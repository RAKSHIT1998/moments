import Foundation

/// Resolves extracted names against the store. Certain matches resolve; uncertain ones
/// stay separate and produce a "Could these be the same person?" suggestion.
struct ContextResolver: Sendable {
    struct PersonResolution: Sendable, Equatable {
        var name: String
        var matchedID: UUID?
        /// A probable-but-uncertain existing person, e.g. "Rahul" vs "Rahul from gym".
        var possibleMatchID: UUID?
        var possibleMatchName: String?
    }

    var context: AnalysisContext

    func resolve(personName: String) -> PersonResolution {
        let lower = personName.lowercased().trimmed
        if let id = context.personCorrections[lower] { return PersonResolution(name: personName, matchedID: id) }
        if let p = context.knownPeople.first(where: { $0.allNames.contains(lower) }) { return PersonResolution(name: p.displayName, matchedID: p.id) }

        // "Rahul Sharma" vs "Rahul", "Rahul from gym" vs "Rahul"
        let first = lower.split(separator: " ").first.map(String.init) ?? lower
        let sameFirst = context.knownPeople.filter { $0.displayName.lowercased().split(separator: " ").first.map(String.init) == first }
        if sameFirst.count == 1, let p = sameFirst.first {
            if lower.contains(" from ") || lower.contains("(") || p.displayName.lowercased() != first || lower.split(separator: " ").count > 1 {
                return PersonResolution(name: personName, matchedID: nil, possibleMatchID: p.id, possibleMatchName: p.displayName)
            }
            return PersonResolution(name: p.displayName, matchedID: p.id)
        }
        return PersonResolution(name: personName, matchedID: nil)
    }

    func resolve(placeName: String) -> UUID? {
        context.knownPlaces.first { $0.name.lowercased() == placeName.lowercased() }?.id
    }
}
