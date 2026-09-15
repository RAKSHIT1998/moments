import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

/// Indexes saved memory titles for iPhone-wide search. Off whenever the app is locked with
/// Face ID (nothing sensitive should be visible outside the app), and cleared on Delete All.
enum SpotlightService {
    static let domain = "com.rakshitbargotra.moment.memories"

    static func reindex(_ memories: [MemorySnapshot], enabled: Bool) {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let index = CSSearchableIndex.default()
        guard enabled else { index.deleteSearchableItems(withDomainIdentifiers: [domain]); return }
        let items = memories.map { m -> CSSearchableItem in
            let attrs = CSSearchableItemAttributeSet(contentType: .text)
            attrs.title = m.title
            attrs.contentDescription = m.summary
            attrs.keywords = m.peopleNames + m.placeNames
            attrs.contentCreationDate = m.createdAt
            let item = CSSearchableItem(uniqueIdentifier: m.id.uuidString, domainIdentifier: domain, attributeSet: attrs)
            return item
        }
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            index.indexSearchableItems(items) { error in
                if let error { Log.app.debug("Spotlight index failed: \(error.localizedDescription)") }
            }
        }
    }

    static func remove(_ id: UUID) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [id.uuidString])
    }

    static func clear() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain])
    }
}
