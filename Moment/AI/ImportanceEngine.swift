import Foundation

/// 0–100 importance. Pure function of the memory's own signals — never of sensitive inference.
enum ImportanceEngine {
    static func score(_ m: ExtractedMemory, now: Date = .now) -> Int {
        var s = 30.0
        switch m.memoryType {
        case .promise: s += 30
        case .task: s += 25
        case .event: s += 25
        case .plan: s += 18
        case .giftIdea: s += 18
        case .personFact: s += 10
        case .place: s += 8
        case .idea: s += 8
        case .purchase: s += 5
        case .link, .reference: s += 0
        case .conversation, .photo, .voiceNote, .unknown: s -= 5
        }
        let lower = m.content.lowercased()
        if lower.matches(#"\b(urgent|asap|important|must|deadline|don'?t forget|remind me)\b"#) { s += 15 }
        if lower.matches(#"\b(passport|visa|tax|taxes|insurance|rent|lease|contract|exam|interview|surgery|flight)\b"#) { s += 10 }
        if let t = m.temporal {
            let days = now.daysUntil(t.start)
            if t.isFuture {
                if days <= 1 { s += 20 } else if days <= 7 { s += 12 } else if days <= 30 { s += 6 }
            }
        }
        if !m.peopleNames.isEmpty { s += 5 }
        if m.event?.isAnnual == true { s += 5 }
        s *= 0.7 + 0.3 * m.confidence
        return Int(max(0, min(100, s.rounded())))
    }

    /// Re-scored from stored state (used when the user edits or time passes).
    static func rescore(base: Int, isPinned: Bool, userEdited: Bool, ageDays: Int, hasOpenItem: Bool) -> Int {
        var s = Double(base)
        if isPinned { s += 25 }
        if userEdited { s += 8 }
        if hasOpenItem { s += 10 }
        if ageDays > 180, !hasOpenItem { s -= 10 }
        return Int(max(0, min(100, s.rounded())))
    }
}
