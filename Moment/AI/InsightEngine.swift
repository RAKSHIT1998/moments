import Foundation

/// Smart cleanup: duplicates, stale plans, completed promises, probable same-person pairs.
/// Produces suggestions only; the user decides. Nothing is ever deleted silently.
struct InsightEngine: Sendable {
    struct PlanInfo: Sendable { var id: UUID; var title: String; var status: PlanStatus; var anchor: Date?; var updatedAt: Date; var memoryIDs: [UUID] }
    struct PromiseInfo: Sendable { var id: UUID; var summary: String; var status: PromiseStatus; var createdAt: Date; var memoryIDs: [UUID] }

    var now: Date

    func duplicateMemories(_ memories: [MemorySnapshot]) -> [InsightDraft] {
        var drafts: [InsightDraft] = []
        var seen: Set<UUID> = []
        let engine = SearchEngine(context: AnalysisContext(now: now))
        for (i, a) in memories.enumerated() where !seen.contains(a.id) {
            var group = [a]
            let aTokens = Set(engine.tokens(a.title + " " + a.summary)).filter { $0.count > 3 }
            for b in memories[(i + 1)...] where !seen.contains(b.id) && b.memoryType == a.memoryType {
                let bTokens = Set(engine.tokens(b.title + " " + b.summary)).filter { $0.count > 3 }
                let overlap = Double(aTokens.intersection(bTokens).count) / Double(max(1, min(aTokens.count, bTokens.count)))
                let samePeople = !a.peopleNames.isEmpty && Set(a.peopleNames.map { $0.lowercased() }) == Set(b.peopleNames.map { $0.lowercased() })
                let samePlace = !a.placeNames.isEmpty && Set(a.placeNames.map { $0.lowercased() }) == Set(b.placeNames.map { $0.lowercased() })
                if overlap >= 0.6 || (samePlace && (a.memoryType == .plan || a.memoryType == .place)) || (samePeople && overlap >= 0.4) {
                    group.append(b)
                }
            }
            if group.count >= 2 {
                group.forEach { seen.insert($0.id) }
                let subject = a.placeNames.first ?? a.peopleNames.first ?? a.memoryType.label.lowercased()
                drafts.append(InsightDraft(
                    kind: "duplicate",
                    title: "You have \(group.count) memories about the same \(a.memoryType == .plan ? "\(subject) plan" : subject)",
                    body: group.map { "• \($0.title)" }.joined(separator: "\n"),
                    memoryIDs: group.map(\.id),
                    personIDs: [],
                    dedupeKey: "dup:" + group.map { $0.id.uuidString }.sorted().joined(separator: ",")
                ))
            }
        }
        return drafts
    }

    func stalePlans(_ plans: [PlanInfo]) -> [InsightDraft] {
        plans.compactMap { plan in
            guard plan.status.isActive else { return nil }
            let idleDays = plan.updatedAt.daysUntil(now)
            let windowPassed = plan.anchor.map { $0.daysUntil(now) > 14 } ?? false
            guard windowPassed || idleDays > 120 else { return nil }
            return InsightDraft(
                kind: "stalePlan",
                title: windowPassed ? "Did \(plan.title) happen?" : "\(plan.title) has been idle for \(idleDays / 30) months",
                body: windowPassed ? "The time you mentioned has passed. Mark it done, reschedule, or let it go." : "Still want to do this?",
                memoryIDs: plan.memoryIDs, personIDs: [],
                dedupeKey: "stale:\(plan.id.uuidString):\(windowPassed ? "passed" : "idle")"
            )
        }
    }

    func longPendingPromises(_ promises: [PromiseInfo]) -> [InsightDraft] {
        promises.compactMap { p in
            guard p.status == .pending, p.createdAt.daysUntil(now) > 45 else { return nil }
            return InsightDraft(kind: "oldPromise", title: "Still pending after \(p.createdAt.daysUntil(now)) days", body: p.summary, memoryIDs: p.memoryIDs, personIDs: [], dedupeKey: "oldpromise:\(p.id.uuidString)")
        }
    }

    /// "Rahul" and "Rahul Sharma" — could these be the same person?
    func probableSamePeople(_ people: [PersonSnapshot]) -> [InsightDraft] {
        var drafts: [InsightDraft] = []
        for (i, a) in people.enumerated() {
            for b in people[(i + 1)...] {
                let af = a.displayName.lowercased().split(separator: " ").first.map(String.init) ?? ""
                let bf = b.displayName.lowercased().split(separator: " ").first.map(String.init) ?? ""
                guard !af.isEmpty, af == bf, a.displayName.lowercased() != b.displayName.lowercased() else { continue }
                drafts.append(InsightDraft(
                    kind: "samePerson",
                    title: "Could these be the same person?",
                    body: "\(a.displayName) and \(b.displayName)",
                    memoryIDs: [], personIDs: [a.id, b.id],
                    dedupeKey: "same:" + [a.id.uuidString, b.id.uuidString].sorted().joined(separator: ",")
                ))
            }
        }
        return drafts
    }
}
