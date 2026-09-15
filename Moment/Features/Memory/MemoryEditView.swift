import SwiftUI

/// Every AI-generated memory is editable. The user is never trapped in an interpretation.
struct MemoryEditView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let memory: Memory
    @State private var title: String
    @State private var summary: String
    @State private var type: MemoryType
    @State private var important: Bool
    @State private var reminder: Date?
    @State private var showReminderPicker = false

    init(memory: Memory) {
        self.memory = memory
        _title = State(initialValue: memory.title)
        _summary = State(initialValue: memory.summary)
        _type = State(initialValue: memory.memoryType)
        _important = State(initialValue: memory.isPinned)
        _reminder = State(initialValue: memory.reminderAt)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What MOMENT remembers") {
                    TextField("Title", text: $title).accessibilityIdentifier("editTitle")
                    TextField("Summary", text: $summary, axis: .vertical).lineLimit(2...5)
                    Picker("Type", selection: $type) {
                        ForEach(MemoryType.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Section {
                    Toggle("Mark important", isOn: $important)
                    Toggle("Remind me", isOn: Binding(get: { reminder != nil }, set: { on in reminder = on ? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date.now.adding(days: 1)) : nil }))
                    if let r = reminder {
                        DatePicker("When", selection: Binding(get: { r }, set: { reminder = $0 }), in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                    }
                }
                if let source = memory.source {
                    Section("Original") {
                        Text(source.originalText ?? memory.content).font(MFont.footnote).foregroundStyle(MColor.textSecondary).lineLimit(8)
                    }
                }
            }
            .navigationTitle("Edit Moment")
            .presentationDetents([.large])
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(title.isBlank).accessibilityIdentifier("editSave") }
            }
        }
    }

    private func save() {
        env.actions.update(memory, title: title, summary: summary, type: type)
        if important != memory.isPinned { env.actions.togglePin(memory) }
        if reminder != memory.reminderAt { env.actions.setReminder(memory, at: reminder) }
        Haptics.saved()
        Task { await env.surface.refresh() }
        dismiss()
    }
}
