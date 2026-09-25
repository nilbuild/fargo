import SwiftUI
import AppKit

// MARK: - Notes Pop-out Window

/// A floating window for private talking points and a checklist, which can also be
/// shown on stream as an overlay.
@MainActor @Observable
final class NotesPopout {
    static let shared = NotesPopout()

    enum Tab: String, CaseIterable {
        case notes = "Notes"
        case checklist = "Checklist"
    }

    private static let showInScreenShareKey = "streamif.notesPopout.showInScreenShare"
    private static let tabKey = "streamif.notesPopout.tab"

    private(set) var isOpen = false

    var tab = Tab(rawValue: UserDefaults.standard.string(forKey: tabKey) ?? "") ?? .notes {
        didSet {
            UserDefaults.standard.set(tab.rawValue, forKey: Self.tabKey)
        }
    }

    /// Off by default, so notes stay private to the streamer.
    var showInScreenShare = UserDefaults.standard.bool(forKey: showInScreenShareKey) {
        didSet {
            UserDefaults.standard.set(showInScreenShare, forKey: Self.showInScreenShareKey)
            applySharingType()
            refreshCaptures()
        }
    }

    var windowNumber: Int? { isOpen ? panel?.windowNumber : nil }

    private var panel: NSPanel?
    private weak var pipeline: MediaPipeline?

    func toggle(pipeline: MediaPipeline) {
        isOpen ? close() : open(pipeline: pipeline)
    }

    func open(pipeline: MediaPipeline, tab: Tab? = nil) {
        self.pipeline = pipeline
        if let tab {
            self.tab = tab
        }
        if panel == nil {
            panel = makePanel(pipeline: pipeline)
        }
        applySharingType()
        panel?.orderFrontRegardless()
        panel?.makeKey()
        isOpen = true
        refreshCaptures()
    }

    func close() {
        panel?.close()
    }

    private func makePanel(pipeline: MediaPipeline) -> NSPanel {
        // Not a non-activating panel like the chat pop-out, since typing notes needs
        // keyboard focus.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 460),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Notes"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(white: 0.05, alpha: 1)
        panel.contentMinSize = NSSize(width: 260, height: 240)
        panel.contentView = NSHostingView(rootView: NotesPopoutView().environment(pipeline))
        if !panel.setFrameUsingName("StreamifNotesPopout") {
            panel.center()
        }
        panel.setFrameAutosaveName("StreamifNotesPopout")

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isOpen = false
                self?.refreshCaptures()
            }
        }
        return panel
    }

    private func applySharingType() {
        panel?.sharingType = showInScreenShare ? .readOnly : .none
    }

    private func refreshCaptures() {
        guard let pipeline else { return }
        Task { await pipeline.refreshScreenCaptureExclusions() }
    }
}

// MARK: - Notes Pop-out View

struct NotesPopoutView: View {
    @Environment(MediaPipeline.self) private var pipeline
    @Bindable private var popout = NotesPopout.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: popout.showInScreenShare ? "eye" : "eye.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(popout.showInScreenShare ? .orange : .white.opacity(0.4))
                    .frame(width: 14)
                Text(popout.showInScreenShare ? "Visible in screen share" : "Hidden from screen share")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Toggle("", isOn: $popout.showInScreenShare)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Show this window when your screen is captured or shared")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(white: 0.04))
            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }

            Picker("", selection: $popout.tab) {
                ForEach(NotesPopout.Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(.horizontal, 12).padding(.vertical, 8)

            switch popout.tab {
            case .notes:
                NotesEditor()
            case .checklist:
                ChecklistEditor()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.05))
    }
}

private struct NotesEditor: View {
    @Environment(MediaPipeline.self) private var pipeline

    var body: some View {
        @Bindable var notes = pipeline.studioNotes

        ZStack(alignment: .topLeading) {
            TextEditor(text: $notes.notes)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)

            if notes.notes.isEmpty {
                Text("Talking points, links, reminders…")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.25))
                    .padding(.horizontal, 13)
                    .allowsHitTesting(false)
            }
        }
        .padding(.bottom, 8)
    }
}

private struct ChecklistEditor: View {
    @Environment(MediaPipeline.self) private var pipeline
    @State private var newItem = ""
    @FocusState private var isAddFocused: Bool

    var body: some View {
        let notes = pipeline.studioNotes

        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 10))
                    .foregroundStyle(pipeline.isChecklistOnStream ? .red : .white.opacity(0.4))
                    .frame(width: 14)
                Text("Show on stream")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { pipeline.isChecklistOnStream },
                    set: { pipeline.showChecklistOnStream($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help("Show the checklist as an overlay, so viewers can see what you are working on")
            }
            .padding(.horizontal, 12).padding(.bottom, 8)

            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                TextField("Add an item", text: $newItem)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isAddFocused)
                    .onSubmit {
                        notes.add(newItem)
                        newItem = ""
                        isAddFocused = true
                    }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 12)

            if notes.items.isEmpty {
                TabEmptyState(
                    icon: "checklist",
                    title: "No items",
                    subtitle: "Add what you plan to cover on this stream"
                )
                .padding(.top, 12)
                Spacer()
            } else {
                List {
                    ForEach(notes.items) { item in
                        ChecklistRow(item: item)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    .onMove { notes.move(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)

                HStack {
                    Text("\(notes.doneCount) of \(notes.items.count) done")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer()
                    if notes.doneCount > 0 {
                        Button("Clear Completed") { notes.clearCompleted() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }
            }
        }
    }
}

private struct ChecklistRow: View {
    @Environment(MediaPipeline.self) private var pipeline
    let item: ChecklistItem
    @State private var isHovered = false

    var body: some View {
        let notes = pipeline.studioNotes

        HStack(spacing: 8) {
            Button { notes.toggle(item.id) } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(item.isDone ? .green : .white.opacity(0.35))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            TextField("", text: Binding(
                get: { item.text },
                set: { notes.rename(item.id, to: $0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .strikethrough(item.isDone, color: .white.opacity(0.35))
            .foregroundStyle(item.isDone ? .white.opacity(0.4) : .white.opacity(0.85))

            Button { notes.remove(item.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .help("Remove item")
        }
        .padding(.vertical, 2)
        .onHover { isHovered = $0 }
    }
}
