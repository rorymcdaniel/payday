import SwiftUI
import AppKit
import PaydayCore

/// A native field editor keeps the cursor at the end as digits shift into cents.
/// Reformatting a SwiftUI TextField binding on each keystroke loses its selection.
struct CentsTextField: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let value: Int64
    let digits: Int
    let large: Bool
    let label: String
    var change: (Int64) -> Void
    var validity: (Bool) -> Void
    var focus: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> SelectAmountField {
        let field = SelectAmountField()
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = NSFont.monospacedDigitSystemFont(ofSize: large ? 30 : 14, weight: .medium)
        field.alignment = large ? .left : .right
        field.textColor = NSColor(calibratedRed: 0.13, green: 0.29, blue: 0.24, alpha: 1)
        field.stringValue = Money.input(value, digits: digits)
        field.delegate = context.coordinator
        field.isEnabled = isEnabled
        field.setAccessibilityLabel(label)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: SelectAmountField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        field.isEnabled = isEnabled
        if coordinator.lastValue != value || coordinator.lastDigits != digits {
            coordinator.lastValue = value; coordinator.lastDigits = digits
            coordinator.display(value, in: field)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CentsTextField
        var lastValue: Int64
        var lastDigits: Int
        init(_ parent: CentsTextField) {
            self.parent = parent; self.lastValue = parent.value; self.lastDigits = parent.digits
        }
        func display(_ amount: Int64, in field: NSTextField) {
            let formatted = Money.input(amount, digits: parent.digits)
            field.stringValue = formatted
            if let editor = field.currentEditor() as? NSTextView {
                editor.string = formatted
                editor.setSelectedRange(NSRange(location: formatted.utf16.count, length: 0))
            }
        }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.focus(true) }
        func controlTextDidEndEditing(_ notification: Notification) { parent.focus(false) }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            do {
                let amount = try Money.minorUnitEntry(field.stringValue, digits: parent.digits)
                lastValue = amount
                display(amount, in: field)
                parent.validity(true)
                parent.change(amount)
            } catch { parent.validity(false) }
        }
    }
}

final class SelectAmountField: NSTextField {
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        currentEditor()?.selectAll(nil)
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { currentEditor()?.selectAll(nil) }
        return accepted
    }
}
