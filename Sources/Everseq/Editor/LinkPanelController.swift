import AppKit
import EverseqCore

/// The two-field link panel for `/link` (SPEC §5.5.2): a small caret-anchored
/// floating panel with Label and URL fields. `Tab` switches fields, `Enter`
/// confirms, `Esc` (or clicking outside) cancels. On confirm the host inserts
/// `[label](url)` at the trigger position.
@MainActor
final class LinkPanelController: NSObject {

    /// A clipboard string that looks like a single web/file URL, else nil
    /// (used to pre-fill the URL field).
    static func plausibleURL(_ string: String?) -> String? {
        guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, !trimmed.contains("\n") else { return nil }
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://")
            || lower.hasPrefix("file://") else { return nil }
        return trimmed
    }

    private var panel: KeyablePanel?
    private var labelField: NSTextField?
    private var urlField: NSTextField?
    private var insertButton: NSButton?
    /// Non-nil result = confirmed (label, url); nil = cancelled. Called once.
    private var onClose: ((String, String)?) -> Void = { _ in }
    private var finished = false

    /// Opens the panel anchored below the caret of `textView`.
    func present(
        anchoredTo textView: NSTextView,
        clipboardURL: String?,
        onClose: @escaping ((String, String)?) -> Void
    ) {
        dismissImmediately()
        self.onClose = onClose
        self.finished = false

        let width: CGFloat = 320
        let pad: CGFloat = 12
        let fieldH: CGFloat = 22
        let rowGap: CGFloat = 8
        let height = pad * 2 + fieldH * 2 + rowGap + 30

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        effect.material = .menu
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8

        // Top field (URL) sits higher in flipped-free AppKit coords; lay out
        // from the top: Label row, then URL row, then buttons at the bottom.
        let labelY = height - pad - fieldH
        let urlY = labelY - rowGap - fieldH

        let labelCaption = caption("Label", x: pad, y: labelY + fieldH + 1, width: 60)
        let urlCaption = caption("URL", x: pad, y: urlY + fieldH + 1, width: 60)
        labelCaption.isHidden = true // captions add clutter; use placeholders instead
        urlCaption.isHidden = true

        let label = NSTextField(frame: NSRect(x: pad, y: labelY, width: width - pad * 2, height: fieldH))
        label.placeholderString = "Label"
        label.font = .systemFont(ofSize: 13)
        label.delegate = self
        label.bezelStyle = .roundedBezel

        let url = NSTextField(frame: NSRect(x: pad, y: urlY, width: width - pad * 2, height: fieldH))
        url.placeholderString = "URL (https://…)"
        url.font = .systemFont(ofSize: 13)
        url.stringValue = clipboardURL ?? ""
        url.delegate = self
        url.bezelStyle = .roundedBezel

        label.nextKeyView = url
        url.nextKeyView = label

        let insert = NSButton(title: "Insert", target: self, action: #selector(confirm))
        insert.bezelStyle = .rounded
        insert.keyEquivalent = "\r"
        insert.frame = NSRect(x: width - pad - 80, y: pad - 2, width: 80, height: 24)
        insert.isEnabled = !(clipboardURL ?? "").isEmpty

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: width - pad - 80 - 84, y: pad - 2, width: 80, height: 24)

        effect.addSubview(labelCaption)
        effect.addSubview(urlCaption)
        effect.addSubview(label)
        effect.addSubview(url)
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
        self.labelField = label
        self.urlField = url
        self.insertButton = insert

        // Anchor below the caret (screen coordinates).
        let caretRect = textView.firstRect(
            forCharacterRange: textView.selectedRange(), actualRange: nil
        )
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
        panel.makeFirstResponder(label)
    }

    private func caption(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 10)
        field.textColor = .secondaryLabelColor
        field.frame = NSRect(x: x, y: y, width: width, height: 12)
        return field
    }

    @objc private func confirm() {
        guard let url = urlField?.stringValue.trimmingCharacters(in: .whitespaces),
              !url.isEmpty else { return }
        let label = labelField?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
        finish((label.isEmpty ? url : label, url))
    }

    @objc private func cancel() {
        finish(nil)
    }

    private func finish(_ result: (String, String)?) {
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
        labelField = nil
        urlField = nil
        insertButton = nil
    }
}

extension LinkPanelController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        insertButton?.isEnabled = !(urlField?.stringValue
            .trimmingCharacters(in: .whitespaces).isEmpty ?? true)
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            confirm()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }
}

/// Borderless panel that can still become key so its text fields accept input.
final class KeyablePanel: NSPanel {
    var onResignKey: (() -> Void)?
    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
