import Foundation

/// What the widget shows. Written by the app's SurfaceEngine; read by the widget extension.
/// Deliberately small: headlines only, no bodies, no images.
public struct WidgetSnapshot: Codable, Sendable {
    public struct Item: Codable, Identifiable, Sendable {
        public var id: UUID
        public var category: String     // "Follow up", "Upcoming", "Plan", ...
        public var headline: String
        public var detail: String?
        public var deepLink: String     // moment://memory/<uuid>
        public init(id: UUID, category: String, headline: String, detail: String? = nil, deepLink: String) {
            self.id = id; self.category = category; self.headline = headline; self.detail = detail; self.deepLink = deepLink
        }
    }

    public var generatedAt: Date
    public var items: [Item]
    public var pendingFollowUps: Int
    public var todayCount: Int
    /// The user opted in to showing content on the Lock Screen. Off by default.
    public var lockScreenAllowed: Bool

    public init(generatedAt: Date = .now, items: [Item] = [], pendingFollowUps: Int = 0, todayCount: Int = 0, lockScreenAllowed: Bool = false) {
        self.generatedAt = generatedAt
        self.items = items
        self.pendingFollowUps = pendingFollowUps
        self.todayCount = todayCount
        self.lockScreenAllowed = lockScreenAllowed
    }

    public static func load() -> WidgetSnapshot? {
        guard let url = AppGroup.widgetSnapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    public func save() throws {
        guard let url = AppGroup.widgetSnapshotURL else { return }
        try JSONEncoder().encode(self).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
