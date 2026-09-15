import UIKit

/// Subtle, purposeful haptics only: capture completed, memory saved, task completed, important confirmation.
@MainActor
enum Haptics {
    static func captureCompleted() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func saved() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func completed() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
}
