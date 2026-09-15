import OSLog

/// Structured logging. Never log memory content, names, or URLs at default level —
/// use `.private` interpolation for anything user-derived.
enum Log {
    static let app = Logger(subsystem: "com.rakshitbargotra.moment", category: "app")
    static let ai = Logger(subsystem: "com.rakshitbargotra.moment", category: "ai")
    static let storage = Logger(subsystem: "com.rakshitbargotra.moment", category: "storage")
    static let capture = Logger(subsystem: "com.rakshitbargotra.moment", category: "capture")
    static let notifications = Logger(subsystem: "com.rakshitbargotra.moment", category: "notifications")
    static let security = Logger(subsystem: "com.rakshitbargotra.moment", category: "security")
    static let store = Logger(subsystem: "com.rakshitbargotra.moment", category: "storekit")
}
