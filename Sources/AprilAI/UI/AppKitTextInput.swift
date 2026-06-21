import AppKit
import SwiftUI

struct AppKitTextInput: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isSecure: Bool

    func makeNSView(context: Context) -> NSTextField {
        let field: NSTextField = isSecure ? NSSecureTextField(frame: .zero) : NSTextField(frame: .zero)
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingMiddle
        field.stringValue = text
        field.target = context.coordinator
        field.action = #selector(Coordinator.commit(_:))
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            self._text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text = field.stringValue
        }

        @MainActor @objc func commit(_ sender: NSTextField) {
            text = sender.stringValue
        }
    }
}
