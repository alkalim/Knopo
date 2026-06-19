import AppKit
import EverseqCore

/// The graphical date picker for `/date` (SPEC §5.5.4): a small caret-anchored
/// floating panel with a month calendar. `Enter` (or Insert) confirms, `Esc`
/// (or clicking outside) cancels. On confirm the host inserts `[[<ISO date>]]`
/// for the chosen day — letting you reference any day, not just today.
@MainActor
final class DatePanelController: NSObject {

    private var panel: KeyablePanel?
    /// Non-nil result = confirmed date; nil = cancelled. Called once.
    private var onClose: (Date?) -> Void = { _ in }
    private var picker: NSDatePicker?
    private var finished = false

    /// Opens the panel anchored below the caret of `textView`, preselecting
    /// `initialDate`.
    func present(
        anchoredTo textView: NSTextView,
        initialDate: Date,
        onClose: @escaping (Date?) -> Void
    ) {
        dismissImmediately()
        self.onClose = onClose
        self.finished = false

        let pad: CGFloat = 12
        let gap: CGFloat = 10
        let buttonH: CGFloat = 24
        let buttonW: CGFloat = 80
        let buttonGap: CGFloat = 8

        let picker = NSDatePicker()
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = [.yearMonthDay] // calendar only, no clock
        picker.datePickerMode = .single
        picker.dateValue = initialDate
        // No blue focus ring around the calendar (it's first responder for
        // keyboard navigation, which would otherwise draw the accent ring).
        picker.focusRingType = .none
        picker.target = self
        picker.action = #selector(dateClicked)
        picker.sizeToFit()
        let pickerSize = picker.frame.size

        let contentW = max(pickerSize.width, buttonW * 2 + buttonGap)
        let width = contentW + pad * 2
        let height = pad + buttonH + gap + pickerSize.height + pad

        picker.frame = NSRect(
            x: pad + (contentW - pickerSize.width) / 2,
            y: height - pad - pickerSize.height,
            width: pickerSize.width, height: pickerSize.height)

        let insert = NSButton(title: "Insert", target: self, action: #selector(confirm))
        insert.bezelStyle = .rounded
        insert.keyEquivalent = "\r"
        insert.frame = NSRect(x: width - pad - buttonW, y: pad, width: buttonW, height: buttonH)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}" // Esc
        cancel.frame = NSRect(x: insert.frame.minX - buttonGap - buttonW, y: pad,
                              width: buttonW, height: buttonH)

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        effect.material = .menu
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.addSubview(picker)
        effect.addSubview(insert)
        effect.addSubview(cancel)

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.contentView = effect
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.onResignKey = { [weak self] in self?.cancel() }

        self.panel = panel
        self.picker = picker

        // Anchor below the caret (screen coordinates); flip above if it would
        // fall off the bottom of the screen.
        let caretRect = textView.firstRect(
            forCharacterRange: textView.selectedRange(), actualRange: nil)
        var frame = NSRect(x: caretRect.minX, y: caretRect.minY - height - 6,
                           width: width, height: height)
        if let screen = textView.window?.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if frame.minY < visible.minY { frame.origin.y = caretRect.maxY + 6 }
            frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - width))
        }
        panel.setFrame(frame, display: true)
        textView.window?.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(picker)
    }

    /// Double-clicking a day confirms immediately; a single click just selects.
    @objc private func dateClicked() {
        if NSApp.currentEvent?.clickCount ?? 1 >= 2 { confirm() }
    }

    @objc private func confirm() {
        finish(picker?.dateValue)
    }

    @objc private func cancel() {
        finish(nil)
    }

    private func finish(_ result: Date?) {
        guard !finished else { return }
        finished = true
        let callback = onClose
        dismissImmediately()
        callback(result)
    }

    private func dismissImmediately() {
        if let panel {
            panel.onResignKey = nil
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        picker = nil
    }
}
