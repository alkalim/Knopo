import AppKit
import SwiftUI

/// In-page find bar (Cmd+F). Edits `Navigator`'s find state; the outline
/// controller does the matching, highlighting, and scrolling, and writes the
/// match count back. Built from native AppKit controls (a real `NSSearchField`
/// and an `NSSegmentedControl` stepper) on a toolbar-material strip, so it reads
/// like the system find bar and manages first responder itself.
struct FindBar: View {
    @EnvironmentObject var nav: Navigator

    var body: some View {
        HStack(spacing: 10) {
            FindSearchField(
                text: $nav.findQuery,
                focusToken: nav.findFocusToken,
                onNext: { nav.findNext() },
                onPrevious: { nav.findPrevious() },
                onCancel: { nav.closeFind() }
            )
            .frame(width: 240, height: 24)

            Text(matchLabel)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            FindStepper(
                enabled: nav.findMatchCount > 0,
                onPrevious: { nav.findPrevious() },
                onNext: { nav.findNext() }
            )
            .fixedSize()
            .help("Previous (⇧⌘G) / Next (⌘G)")

            Button("Done") { nav.closeFind() }
                .keyboardShortcut(.cancelAction) // Esc closes

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var matchLabel: String {
        if nav.findQuery.isEmpty { return "" }
        if nav.findMatchCount == 0 { return L("No matches") }
        return String(localized: "\(nav.findOrdinal) of \(nav.findMatchCount)",
                      comment: "Find bar: which match of how many is selected")
    }
}

/// Native `NSSearchField`: the rounded capsule, inset magnifier, and clear
/// button a plain SwiftUI `TextField` can't reproduce. It also grabs first
/// responder itself (in `makeNSView`), which is more reliable than SwiftUI
/// `@FocusState` when a block editor was just resigned. Return / Shift-Return
/// step matches; Esc closes.
struct FindSearchField: NSViewRepresentable {
    @Binding var text: String
    /// Bumped by `Navigator.openFind()`; each new value re-focuses the field and
    /// selects its text, so a repeat Cmd+F (even while the bar is already open)
    /// returns focus to the field with the query selected.
    var focusToken: Int
    var onNext: () -> Void
    var onPrevious: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true // incremental: match as you type
        field.sendsWholeSearchString = false
        field.placeholderString = String(localized: "Find in page",
                                         comment: "Find bar search field placeholder")
        field.focusRingType = .none
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if focusToken != context.coordinator.lastFocusToken {
            context.coordinator.lastFocusToken = focusToken
            // Deferred: the field may not be in the window yet on first show.
            // `selectText` both focuses and selects the whole query.
            DispatchQueue.main.async { [weak field] in field?.selectText(nil) }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: FindSearchField
        var lastFocusToken = 0
        init(_ parent: FindSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                    ? parent.onPrevious() : parent.onNext()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

/// A two-segment `NSSegmentedControl` (momentary) for previous / next match —
/// the native stepper look, replacing two borderless SwiftUI buttons.
struct FindStepper: NSViewRepresentable {
    var enabled: Bool
    var onPrevious: () -> Void
    var onNext: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let seg = NSSegmentedControl(
            images: [
                NSImage(systemSymbolName: "chevron.up",
                        accessibilityDescription: L("Previous match"))!,
                NSImage(systemSymbolName: "chevron.down",
                        accessibilityDescription: L("Next match"))!,
            ],
            trackingMode: .momentary,
            target: context.coordinator,
            action: #selector(Coordinator.clicked(_:))
        )
        seg.segmentStyle = .rounded
        return seg
    }

    func updateNSView(_ seg: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        seg.setEnabled(enabled, forSegment: 0)
        seg.setEnabled(enabled, forSegment: 1)
    }

    final class Coordinator: NSObject {
        var parent: FindStepper
        init(_ parent: FindStepper) { self.parent = parent }

        @objc func clicked(_ sender: NSSegmentedControl) {
            sender.selectedSegment == 0 ? parent.onPrevious() : parent.onNext()
        }
    }
}
