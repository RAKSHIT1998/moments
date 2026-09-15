import SwiftUI

/// Export formats. Logical canvas is 360 pt wide (or 640 for landscape); exports at 3× → 1080 px.
enum StoryFormat: String, CaseIterable, Identifiable {
    case story = "9:16", square = "1:1", portrait = "4:5", wide = "16:9"
    var id: String { rawValue }
    var size: CGSize {
        switch self {
        case .story: CGSize(width: 360, height: 640)
        case .square: CGSize(width: 360, height: 360)
        case .portrait: CGSize(width: 360, height: 450)
        case .wide: CGSize(width: 640, height: 360)
        }
    }
    var label: String {
        switch self {
        case .story: "Story · 9:16"; case .square: "Square · 1:1"; case .portrait: "Post · 4:5"; case .wide: "Wide · 16:9"
        }
    }
}

/// Look derived from the template style. Restrained: one accent, big type, real photos.
struct StoryTheme: Equatable {
    var background: Color
    var backgroundSecondary: Color
    var foreground: Color
    var muted: Color
    var accent: Color
    var paper: Bool
    var serif: Bool

    static func from(_ style: MomentTemplate.Style) -> StoryTheme {
        switch style {
        case .cinematic, .emotional, .trip:
            return StoryTheme(background: Color(red: 0.06, green: 0.06, blue: 0.08), backgroundSecondary: Color(red: 0.12, green: 0.12, blue: 0.16), foreground: .white, muted: .white.opacity(0.72), accent: Color(red: 0.62, green: 0.58, blue: 1.0), paper: false, serif: style == .emotional)
        case .polaroid:
            return StoryTheme(background: Color(red: 0.96, green: 0.95, blue: 0.92), backgroundSecondary: .white, foreground: Color(red: 0.12, green: 0.11, blue: 0.10), muted: Color(red: 0.45, green: 0.43, blue: 0.40), accent: Color(red: 0.85, green: 0.35, blue: 0.25), paper: true, serif: true)
        case .chat, .funny:
            return StoryTheme(background: Color(red: 0.98, green: 0.97, blue: 0.95), backgroundSecondary: .white, foreground: Color(red: 0.1, green: 0.1, blue: 0.12), muted: Color(red: 0.45, green: 0.45, blue: 0.5), accent: Color(red: 0.30, green: 0.42, blue: 0.98), paper: true, serif: false)
        case .minimal, .timeline, .quote, .people, .stats:
            return StoryTheme(background: Color(red: 0.97, green: 0.97, blue: 0.96), backgroundSecondary: .white, foreground: Color(red: 0.08, green: 0.08, blue: 0.1), muted: Color(red: 0.42, green: 0.42, blue: 0.46), accent: Color(red: 0.27, green: 0.31, blue: 0.86), paper: false, serif: false)
        }
    }
}

/// Renders one slide at a logical size. Used live in the viewer/editor and by the exporters.
struct StorySlideView: View {
    let slide: StorySlide
    let theme: StoryTheme
    let format: StoryFormat
    var image: UIImage?
    var author: String? = nil
    /// Ken Burns progress 0…1 for video frames; nil for static.
    var motion: Double? = nil
    var showWatermark = true

    private var size: CGSize { format.size }
    private var isWide: Bool { format == .wide }
    private var display: Font { theme.serif ? .system(size: isWide ? 34 : 40, weight: .bold, design: .serif) : .system(size: isWide ? 34 : 40, weight: .bold) }
    private var title: Font { theme.serif ? .system(size: 26, weight: .semibold, design: .serif) : .system(size: 26, weight: .semibold) }
    private var body1: Font { .system(size: 15, weight: .regular) }
    private var caption: Font { .system(size: 12, weight: .medium) }

    var body: some View {
        ZStack {
            theme.background
            content
            if showWatermark { watermark }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .environment(\.colorScheme, theme.paper ? .light : (theme.foreground == .white ? .dark : .light))
    }

    @ViewBuilder private var content: some View {
        switch slide.kind {
        case .cover: cover
        case .photo: photo
        case .quote: quote
        case .stats: stats
        case .people, .places: names
        case .timeline: timeline
        case .list: list
        case .closing: closing
        case .side: side
        }
    }

    // MARK: Slides

    private var cover: some View {
        ZStack(alignment: .bottomLeading) {
            if let image {
                kenBurns(image)
                LinearGradient(colors: [.clear, .black.opacity(0.15), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            }
            VStack(alignment: .leading, spacing: 10) {
                if let d = slide.date { Text(d.formatted(.dateTime.month(.wide).year()).uppercased()).font(caption).tracking(1.5).foregroundStyle(image == nil ? theme.muted : .white.opacity(0.8)) }
                Text(slide.title).font(display).tracking(-1).foregroundStyle(image == nil ? theme.foreground : .white).lineLimit(3).minimumScaleFactor(0.6)
                Text(slide.body).font(body1).foregroundStyle(image == nil ? theme.muted : .white.opacity(0.85))
            }
            .padding(28)
        }
    }

    private var photo: some View {
        ZStack(alignment: .bottomLeading) {
            if theme.paper {
                VStack(spacing: 0) {
                    if let image { Image(uiImage: image).resizable().scaledToFill().frame(width: size.width - 56, height: (isWide ? size.height : size.width) - 56).clipped() }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(slide.title.isBlank ? (slide.caption ?? "") : slide.title).font(theme.serif ? .system(size: 18, weight: .semibold, design: .serif) : .system(size: 18, weight: .semibold)).foregroundStyle(theme.foreground).lineLimit(2)
                        if let d = slide.date { Text(d.mediumDate).font(caption).foregroundStyle(theme.muted) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6).padding(.vertical, 14)
                }
                .padding(14)
                .background(theme.backgroundSecondary)
                .rotationEffect(.degrees(-1.5))
                .shadow(color: .black.opacity(0.15), radius: 14, y: 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if let image { kenBurns(image) } else { theme.backgroundSecondary }
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 6) {
                    if !slide.title.isBlank { Text(slide.title).font(title).foregroundStyle(.white).lineLimit(3) }
                    HStack(spacing: 8) {
                        if let d = slide.date { Text(d.mediumDate) }
                        if let c = slide.caption { Text("·"); Text(c) }
                    }
                    .font(caption).foregroundStyle(.white.opacity(0.8))
                }
                .padding(28)
            }
        }
    }

    private var quote: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Text("“").font(.system(size: 72, weight: .bold, design: .serif)).foregroundStyle(theme.accent).frame(height: 40)
            Text(slide.title).font(theme.serif ? .system(size: 30, weight: .semibold, design: .serif) : .system(size: 30, weight: .bold)).tracking(-0.5).foregroundStyle(theme.foreground).minimumScaleFactor(0.6)
            if !slide.body.isBlank { Text("— \(slide.body)").font(body1).foregroundStyle(theme.muted) }
            if let d = slide.date { Text(d.mediumDate).font(caption).foregroundStyle(theme.muted) }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(slide.title).font(display).tracking(-1).foregroundStyle(theme.foreground)
            let pairs = slide.items.map { $0.split(separator: "|", maxSplits: 1).map(String.init) }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 18) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.first ?? "").font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(theme.accent)
                        Text(p.count > 1 ? p[1] : "").font(body1).foregroundStyle(theme.muted)
                    }
                }
            }
            if !slide.body.isBlank { Text(slide.body).font(body1).foregroundStyle(theme.foreground).padding(.top, 4) }
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(slide.title).font(display).tracking(-1).foregroundStyle(theme.foreground)
            if !slide.body.isBlank { Text(slide.body).font(body1).foregroundStyle(theme.muted) }
            ForEach(slide.items, id: \.self) { item in
                let p = item.split(separator: "|", maxSplits: 1).map(String.init)
                HStack {
                    Text(p.first ?? item).font(title).foregroundStyle(theme.foreground)
                    Spacer()
                    if p.count > 1 { Text("\(p[1]) memor\(p[1] == "1" ? "y" : "ies")").font(caption).foregroundStyle(theme.muted) }
                }
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(theme.muted.opacity(0.2)).frame(height: 1) }
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(slide.title).font(display).tracking(-1).foregroundStyle(theme.foreground)
            ForEach(slide.items, id: \.self) { item in
                let p = item.split(separator: "|", maxSplits: 1).map(String.init)
                HStack(alignment: .top, spacing: 12) {
                    Text(p.first ?? "").font(caption).foregroundStyle(theme.accent).frame(width: 56, alignment: .trailing)
                    Circle().fill(theme.accent).frame(width: 6, height: 6).padding(.top, 5)
                    Text(p.count > 1 ? p[1] : "").font(body1).foregroundStyle(theme.foreground).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(slide.title).font(display).tracking(-1).foregroundStyle(theme.foreground)
            if !slide.body.isBlank { Text(slide.body).font(body1).foregroundStyle(theme.muted) }
            ForEach(slide.items, id: \.self) { item in
                let p = item.split(separator: "|", maxSplits: 1).map(String.init)
                HStack(alignment: .firstTextBaseline) {
                    Text(p.first ?? item).font(title).foregroundStyle(theme.foreground).lineLimit(2)
                    Spacer()
                    if p.count > 1 { Text(p[1]).font(caption).foregroundStyle(p[1] == "Done" ? theme.accent : theme.muted) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var closing: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Text(slide.title).font(display).tracking(-1).foregroundStyle(theme.foreground).minimumScaleFactor(0.7)
            HStack(spacing: 8) {
                Image(systemName: "m.square.fill").foregroundStyle(theme.accent)
                Text("Made with MOMENT").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.muted)
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var side: some View {
        ZStack(alignment: .bottomLeading) {
            if let image { kenBurns(image); LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom) } else { theme.backgroundSecondary }
            VStack(alignment: .leading, spacing: 8) {
                Text("\(slide.body)'s side".uppercased()).font(caption).tracking(1.2).foregroundStyle(image == nil ? theme.accent : .white.opacity(0.8))
                Text(slide.title).font(title).foregroundStyle(image == nil ? theme.foreground : .white)
            }
            .padding(28)
        }
    }

    private var watermark: some View {
        VStack { Spacer(); HStack { Spacer()
            Text("MOMENT").font(.system(size: 9, weight: .bold)).tracking(1.5).foregroundStyle((theme.foreground == .white || image != nil) ? Color.white.opacity(0.55) : theme.muted.opacity(0.7))
                .padding(.trailing, 14).padding(.bottom, 12)
        } }
        .allowsHitTesting(false)
    }

    private func kenBurns(_ image: UIImage) -> some View {
        let t = motion ?? 0
        let scale = 1.0 + 0.08 * t
        return Image(uiImage: image).resizable().scaledToFill()
            .frame(width: size.width, height: size.height)
            .scaleEffect(scale)
            .offset(x: -6 * t, y: -8 * t)
            .clipped()
    }
}
