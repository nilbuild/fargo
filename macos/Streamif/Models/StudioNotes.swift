import SwiftUI

struct ChecklistItem: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var isDone: Bool

    init(text: String) {
        self.id = UUID()
        self.text = text
        self.isDone = false
    }
}

/// The streamer's private notes and the checklist, which can also be shown on stream
/// through a checklist overlay.
@MainActor @Observable
final class StudioNotes {
    private static let notesKey = "streamif.studioNotes.notes"
    private static let checklistKey = "streamif.studioNotes.checklist"

    var notes = UserDefaults.standard.string(forKey: notesKey) ?? "" {
        didSet {
            UserDefaults.standard.set(notes, forKey: Self.notesKey)
        }
    }

    private(set) var items: [ChecklistItem] = StudioNotes.loadItems() {
        didSet {
            if let data = try? JSONEncoder().encode(items) {
                UserDefaults.standard.set(data, forKey: Self.checklistKey)
            }
            onItemsChanged?(items)
        }
    }

    var onItemsChanged: (([ChecklistItem]) -> Void)?

    var doneCount: Int {
        items.filter(\.isDone).count
    }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return
        }
        items.append(ChecklistItem(text: trimmed))
    }

    func toggle(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].isDone.toggle()
    }

    func rename(_ id: UUID, to text: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].text = text
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    func clearCompleted() {
        items.removeAll(where: \.isDone)
    }

    private static func loadItems() -> [ChecklistItem] {
        guard let data = UserDefaults.standard.data(forKey: checklistKey),
              let saved = try? JSONDecoder().decode([ChecklistItem].self, from: data) else { return [] }
        return saved
    }
}
