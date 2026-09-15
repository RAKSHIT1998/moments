import Foundation

/// Constants shared between the app, the Share Extension and the Widget.
/// Everything that crosses a process boundary goes through the App Group container.
public enum AppGroup {
    public static let identifier = "group.com.rakshitbargotra.moment"
    public static let urlScheme = "moment"

    /// Root of the shared container. `nil` only when entitlements are missing.
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Items dropped by the Share Extension, waiting for the app to ingest them.
    public static var shareInboxURL: URL? {
        containerURL?.appending(path: "ShareInbox", directoryHint: .isDirectory)
    }

    /// Small JSON snapshot the app writes for the widget. Never contains raw memory content
    /// beyond the short headline the user would see on Home anyway.
    public static var widgetSnapshotURL: URL? {
        containerURL?.appending(path: "widget-snapshot.json", directoryHint: .notDirectory)
    }

    public static let widgetKind = "MomentWidget"
    public static let followUpsWidgetKind = "MomentFollowUpsWidget"
    public static let todayWidgetKind = "MomentTodayWidget"
    public static let lockScreenWidgetKind = "MomentLockScreenWidget"
}
