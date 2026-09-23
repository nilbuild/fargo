import SwiftUI
import AppKit

// MARK: - Window Accessor

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                configureWindow(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                configureWindow(window)
            }
        }
    }

    private func configureWindow(_ window: NSWindow) {
        window.isMovableByWindowBackground = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.backgroundColor = NSColor(red: 0.03, green: 0.03, blue: 0.04, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)

        if let savedFrame = Persistence.loadWindowFrame() {
            window.setFrame(savedFrame, display: true)
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main
        ) { _ in Persistence.saveWindowFrame(window.frame) }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { _ in Persistence.saveWindowFrame(window.frame) }
    }
}

// MARK: - Traffic Light Buttons

struct TrafficLightButton: View {
    let type: TrafficLightType
    let isGroupHovered: Bool
    let action: () -> Void
    @State private var isPressed = false

    enum TrafficLightType {
        case close, minimize, zoom

        var color: Color {
            switch self {
            case .close: return Color(red: 1.0, green: 0.38, blue: 0.35)
            case .minimize: return Color(red: 1.0, green: 0.74, blue: 0.18)
            case .zoom: return Color(red: 0.15, green: 0.80, blue: 0.26)
            }
        }

        var icon: String {
            switch self {
            case .close: return "xmark"
            case .minimize: return "minus"
            case .zoom: return "plus"
            }
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isGroupHovered ? (isPressed ? type.color.opacity(0.7) : type.color) : Color.white.opacity(0.12))
                    .frame(width: 12, height: 12)

                if isGroupHovered {
                    Image(systemName: type.icon)
                        .font(.system(size: 6, weight: .bold))
                        .foregroundColor(.black.opacity(0.5))
                }
            }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

struct TrafficLights: View {
    @State private var isHovered = false
    @State private var window: NSWindow?

    var body: some View {
        HStack(spacing: 8) {
            TrafficLightButton(type: .close, isGroupHovered: isHovered) { window?.close() }
            TrafficLightButton(type: .minimize, isGroupHovered: isHovered) { window?.miniaturize(nil) }
            TrafficLightButton(type: .zoom, isGroupHovered: isHovered) { window?.zoom(nil) }
        }
        .padding(6)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .background(GeometryReader { _ in
            Color.clear.onAppear {
                DispatchQueue.main.async {
                    window = NSApp.keyWindow
                }
            }
        })
    }
}

// MARK: - Window Drag Area

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DraggableView { DraggableView() }
    func updateNSView(_ nsView: DraggableView, context: Context) {}
}

class DraggableView: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func mouseDragged(with event: NSEvent) { window?.performDrag(with: event) }
}

// MARK: - Tooltip

// SwiftUI's .tooltip() crashes on macOS 27 when its tooltip hit-test reaches an NSViewRepresentable,
// so tooltips go through AppKit's own NSView.toolTip instead.
struct TooltipView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> PassthroughView {
        let view = PassthroughView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ nsView: PassthroughView, context: Context) {
        if nsView.toolTip != text {
            nsView.toolTip = text
        }
    }
}

class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension View {
    func tooltip(_ text: String) -> some View {
        background(TooltipView(text: text))
    }
}
