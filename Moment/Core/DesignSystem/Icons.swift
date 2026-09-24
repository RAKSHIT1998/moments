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

/// One tab's worth of identity, so the bar and the routing can't disagree about what a tab is.
extension RootTab {
    var icons: (off: String, on: String) {
        switch self {
        case .home: MSymbol.home
        case .create: MSymbol.create
        case .chats: MSymbol.chats
        case .profile: MSymbol.profile
        }
    }
    /// Create is an action, not a place — the bar draws it as one.
    var isAction: Bool { self == .create }
}

/// The bar itself: a floating glass pill rather than a slab welded to the bottom of the screen.
///
/// Floating buys two real things, not just a look. Content scrolls *under* it, so a feed reads as one
/// continuous column instead of ending at a hard edge; and the bar can sit inside the safe area with
/// the home indicator visible beneath it, which stops the last row of any list hiding behind the chrome.
struct FloatingTabBar: View {
    @Binding var selection: RootTab
    /// Unread count on Chats. Zero hides the dot entirely rather than drawing a "0".
    var unreadChats: Int = 0
    var onCreate: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 4) {
            ForEach(RootTab.allCases) { tab in
                if tab.isAction { createButton } else { item(tab) }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .glassPill(prominent: true)
        .padding(.horizontal, MSpacing.page)
        // `.contain` matters: without it the container's identifier is inherited by every button in
        // the bar and each tab stops being addressable on its own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("floatingTabBar")
    }

    private func item(_ tab: RootTab) -> some View {
        let selected = selection == tab
        return Button {
            if !reduceMotion { Haptics.selection() }
            selection = tab
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    // The selected tab keeps a soft lens behind it that slides between tabs.
                    if selected {
                        Capsule().fill(MColor.accent.opacity(0.16))
                            .matchedGeometryEffect(id: "selected", in: pill)
                            .frame(height: 30)
                    }
                    Image(systemName: selected ? tab.icons.on : tab.icons.off)
                        .font(.system(size: 19, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? MColor.accent : MColor.textSecondary)
                        .overlay(alignment: .topTrailing) {
                            if tab == .chats, unreadChats > 0 {
                                Circle().fill(MColor.danger)
                                    .frame(width: 8, height: 8)
                                    .offset(x: 5, y: -3)
                                    .accessibilityHidden(true)
                            }
                        }
                }
                .frame(height: 30)
                Text(tab.label)
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? MColor.accent : MColor.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.78), value: selection)
        .accessibilityIdentifier("tab-\(tab.label)")
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Create is the only thing in the bar that does something rather than going somewhere, so it is the
    /// only thing drawn as a solid button.
    private var createButton: some View {
        Button {
            Haptics.selection()
            onCreate()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 38)
                .background(
                    Capsule().fill(LinearGradient(colors: [MColor.accent, MColor.accent.opacity(0.82)],
                                                  startPoint: .top, endPoint: .bottom))
                )
                .shadow(color: MColor.accent.opacity(0.45), radius: 10, y: 4)
        }
        .buttonStyle(PressScaleStyle())
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("tab-Create")
        .accessibilityLabel("Create")
    }
}
