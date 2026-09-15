import Foundation

/// "Delete All Data" and friends. No hidden retention.
@MainActor
final class DataLifecycleService {
    private let storage: StorageService
    private let media: MediaStore
    private let settings: SettingsStore
    private let notifications: NotificationService
    private let analytics: AnalyticsService

    init(storage: StorageService, media: MediaStore, settings: SettingsStore, notifications: NotificationService, analytics: AnalyticsService) {
        self.storage = storage
        self.media = media
        self.settings = settings
        self.notifications = notifications
        self.analytics = analytics
    }

    /// Permanently deletes memories, entities, media, encryption key, widget snapshot, share inbox,
    /// notifications, analytics counters and the cloud AI key.
    func deleteEverything() async throws {
        try storage.deleteEverything()
        await media.deleteAll()
        FileCrypto.destroyKey()
        Keychain.delete(RemoteIntelligenceProvider.keychainKey)
        ShareInbox.removeAll()
        if let url = AppGroup.widgetSnapshotURL { try? FileManager.default.removeItem(at: url) }
        notifications.cancelAll()
        SpotlightService.clear()
        analytics.reset()
        settings.resetAll()
        Log.storage.notice("All data deleted by user request")
    }

    /// Removes stored screenshots/audio/files but keeps the text memories.
    func clearImportedMedia() async {
        await media.deleteAll()
        for m in storage.fetchMemories(includeArchived: true, includeUnreviewed: true) {
            m.imagePath = nil; m.audioPath = nil
            m.source?.imageReference = nil; m.source?.audioReference = nil; m.source?.fileReference = nil
        }
        storage.save()
    }

    func mediaSize() async -> Int64 { await media.totalSize() }
}
