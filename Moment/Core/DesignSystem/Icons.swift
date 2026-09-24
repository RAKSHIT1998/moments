import SwiftUI

/// Every icon in MOMENT, named by what it means rather than by which glyph it happens to be.
///
/// The pack is **SF Symbols**, deliberately. It is the only set on iOS that scales with Dynamic Type,
/// tracks the text weight around it, has a filled and an outline variant of nearly everything, and is
/// already localised and described to VoiceOver. A bundled third-party pack would look consistent with
/// itself and wrong next to every system control the app uses — the share sheet, the keyboard, the
/// context menus — and would lose all of that for nothing.
///
/// Naming them here rather than scattering `Image(systemName: "bubble.left")` through forty files means
/// a change of visual language is one file, and two screens can't drift apart by accident.
enum MSymbol {
    // Tabs — outline when resting, filled when selected. That pairing is the whole grammar of the bar.
    static let home = (off: "house", on: "house.fill")
    static let create = (off: "plus.circle", on: "plus.circle.fill")
    static let chats = (off: "bubble.left.and.bubble.right", on: "bubble.left.and.bubble.right.fill")
    static let profile = (off: "person.crop.circle", on: "person.crop.circle.fill")

    // The feed and what's in it
    static let reels = "play.rectangle.on.rectangle"
    static let notifications = "bell"
    static let notificationsOn = "bell.badge.fill"
    static let locked = "lock.fill"
    static let unlocked = "lock.open.fill"
    static let subscription = "crown.fill"
    static let photoSet = "photo.stack"
    static let videoPost = "play.rectangle.fill"
    static let tip = "gift.fill"
    static let shop = "bag.fill"

    // People and money
    static let follow = "person.badge.plus"
    static let following = "person.2"
    static let subscribers = "heart.text.square"
    static let earnings = "chart.line.uptrend.xyaxis"
    static let payout = "indianrupeesign.circle"

    // Calls and time
    static let videoCall = "video.fill"
    static let voiceCall = "phone.fill"
    static let hangUp = "phone.down.fill"
    static let mic = "mic.fill"
    static let micOff = "mic.slash.fill"
    static let cameraOn = "video.fill"
    static let cameraOff = "video.slash.fill"
    static let flipCamera = "arrow.triangle.2.circlepath.camera"
    static let speaker = "speaker.wave.2.fill"
    static let earpiece = "speaker.fill"
    static let clock = "clock"
    static let calendar = "calendar.badge.clock"

    // Messaging
    static let send = "arrow.up"
    static let attach = "photo"
    static let voiceNote = "mic"
    static let reply = "arrowshape.turn.up.left"
    static let massMessage = "megaphone.fill"

    // Safety and state
    static let shield = "shield"
    static let report = "flag"
    static let block = "hand.raised"
    static let hidden = "eye.slash"
    static let verified = "checkmark.seal.fill"
    static let more = "ellipsis"
    static let close = "xmark"
    static let back = "chevron.left"
    static let disclosure = "chevron.right"
    static let settings = "gearshape"
    static let key = "key"
    static let privateMemory = "lock"
}
