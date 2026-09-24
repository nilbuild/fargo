import SwiftUI
import AppKit

class InlineNSTextField: NSTextField {
    var hasFocused = false
    var shouldAutoFocus = false
    var shouldSelectAll = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard window != nil, shouldAutoFocus, !hasFocused else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.attemptFocus()
        }
    }

    private func attemptFocus() {
        guard let window = window, !hasFocused else {
            return
        }

        if window.makeFirstResponder(self) {
            hasFocused = true
            if shouldSelectAll {
                selectText(nil)
                if let editor = currentEditor() {
                    editor.selectedRange = NSRange(location: 0, length: stringValue.count)
                }
            }
        }
    }
}

struct InlineTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var font: NSFont = .systemFont(ofSize: 11)
    var textColor: NSColor = .white.withAlphaComponent(0.9)
    var autoFocus: Bool = false
    var selectAllOnFocus: Bool = false
    var isSecure: Bool = false
    var focusTrigger: Int = 0
    var onCommit: () -> Void = {}
    var onCancel: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSTextField {
        let textField = isSecure ? NSSecureTextField() : InlineNSTextField()
        textField.delegate = context.coordinator
        textField.isBordered = false
        textField.drawsBackground = false
        textField.backgroundColor = .clear
        textField.font = font
        textField.textColor = textColor
        textField.focusRingType = .none
        textField.cell?.lineBreakMode = .byTruncatingTail
        textField.cell?.isScrollable = true
        textField.stringValue = text
        textField.placeholderString = placeholder
        if let inlineField = textField as? InlineNSTextField {
            inlineField.shouldAutoFocus = autoFocus
            inlineField.shouldSelectAll = selectAllOnFocus
        }
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.lastFocusTrigger = focusTrigger
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text && nsView.currentEditor() == nil {
            nsView.stringValue = text
        }
        nsView.textColor = textColor
        nsView.font = font

        if focusTrigger != context.coordinator.lastFocusTrigger {
            context.coordinator.lastFocusTrigger = focusTrigger
            DispatchQueue.main.async { [weak nsView] in
                guard let nsView, let window = nsView.window else {
                    return
                }
                if window.firstResponder === nsView.currentEditor() {
                    return
                }
                window.makeFirstResponder(nsView)
                if let editor = nsView.currentEditor() {
                    let length = nsView.stringValue.count
                    editor.selectedRange = NSRange(location: length, length: 0)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineTextField
        var lastFocusTrigger: Int = 0

        init(_ parent: InlineTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            if let textField = obj.object as? NSTextField {
                parent.text = textField.stringValue
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.onCommit()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onCommit()
                control.window?.makeFirstResponder(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel?()
                control.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }
    }
}

extension View {
    // InlineTextField wraps NSTextField, so its hit area is only the raw text bounds.
    // SwiftUI padding around it is dead space for click-to-focus. Apply this on the
    // outer styled container so a click anywhere on the row focuses the field.
    func focusesInlineField(on token: Binding<Int>) -> some View {
        self
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded { token.wrappedValue &+= 1 }
            )
    }
}
