import SwiftUI

/// Design tokens beyond color/spacing/type. Every screen uses these; no magic numbers in views.
enum MRadius {
    static let card: CGFloat = 24
    static let tile: CGFloat = 20
    static let control: CGFloat = 18
    static let chip: CGFloat = 12
    static let icon: CGFloat = 12
}

enum MIcon {
    static let small: CGFloat = 16
    static let medium: CGFloat = 22
    static let tile: CGFloat = 44
    static let hero: CGFloat = 68
}

enum MShadow {
    static let card = (color: Color.black.opacity(0.05), radius: CGFloat(14), y: CGFloat(6))
    static let accent = (color: Color.accentColor.opacity(0.35), radius: CGFloat(16), y: CGFloat(8))
}

/// Motion: short, purposeful. Every animation honours Reduce Motion via `MAnimation.spring(reduce:)`.
enum MAnimation {
    static let quick: Animation = .spring(duration: 0.25)
    static let standard: Animation = .spring(duration: 0.35, bounce: 0.15)
    static let gentle: Animation = .easeInOut(duration: 0.3)
    static func spring(reduce: Bool) -> Animation? { reduce ? nil : standard }
}

/// Minimum touch target.
enum MTouch { static let minimum: CGFloat = 44 }
