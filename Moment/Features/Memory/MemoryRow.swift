import SwiftUI

/// Compact row used in lists (Inbox, People, Timeline, Search).
struct MemoryRow: View {
    let memory: Memory
    var showDate = true
    var reason: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: MSpacing.m) {
            Image(systemName: memory.memoryType.symbol)
                .font(.body)
                .foregroundStyle(MColor.accent)
                .frame(width: 28, height: 28)
                .background(MColor.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(memory.title).font(MFont.headline).lineLimit(2)
                if !memory.summary.isEmpty { Text(memory.summary).font(MFont.subheadline).foregroundStyle(MColor.textSecondary).lineLimit(2) }
                HStack(spacing: 6) {
                    if let reason { Text(reason).font(MFont.caption).foregroundStyle(MColor.accent) }
                    else {
                        if showDate { Text(memory.createdAt.relativeDescription) }
                        if let s = memory.source { Text("·"); Label(s.type.label, systemImage: s.type.symbol).labelStyle(.titleOnly) }
                        if memory.confidence == .low { Text("·"); Text("Needs review").foregroundStyle(MColor.warning) }
                    }
                }
                .font(MFont.caption)
                .foregroundStyle(MColor.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(memory.memoryType.label): \(memory.title). \(memory.summary)")
    }
}
