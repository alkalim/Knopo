import AppKit
import Testing
@testable import Knopo

/// Which tab `⌘1`…`⌘9` picks (SPEC §12).
@MainActor
@Suite struct TabShortcutTests {

    @Test func digitsPickTheirOwnTab() {
        #expect(TabShortcuts.tabIndex(forDigit: 1, tabCount: 4) == 0)
        #expect(TabShortcuts.tabIndex(forDigit: 3, tabCount: 4) == 2)
        #expect(TabShortcuts.tabIndex(forDigit: 8, tabCount: 9) == 7)
    }

    /// `⌘9` is the last tab, not the ninth, as in Safari.
    @Test func nineIsTheLastTab() {
        #expect(TabShortcuts.tabIndex(forDigit: 9, tabCount: 3) == 2)
        #expect(TabShortcuts.tabIndex(forDigit: 9, tabCount: 12) == 11)
        #expect(TabShortcuts.tabIndex(forDigit: 9, tabCount: 9) == 8)
    }

    /// A digit past the last tab selects nothing, leaving the key to anyone else.
    @Test func digitsBeyondTheTabsSelectNothing() {
        #expect(TabShortcuts.tabIndex(forDigit: 5, tabCount: 3) == nil)
        #expect(TabShortcuts.tabIndex(forDigit: 2, tabCount: 2) == 1)
    }

    /// `⌘0` is Actual Size, and a lone window is no tab group.
    @Test func zeroAndSingleWindowsAreLeftAlone() {
        #expect(TabShortcuts.tabIndex(forDigit: 0, tabCount: 4) == nil)
        #expect(TabShortcuts.tabIndex(forDigit: 1, tabCount: 1) == nil)
        #expect(TabShortcuts.tabIndex(forDigit: 1, tabCount: 0) == nil)
    }

    private func keyDown(_ characters: String, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                         timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: 0)!
    }

    /// Only a plain `⌘`-digit is a tab shortcut. Zoom and line spacing are
    /// bound to the same keys with other modifiers and must keep their events.
    @Test func onlyPlainCommandDigitsCount() {
        #expect(TabShortcuts.digit(for: keyDown("2", .command)) == 2)
        #expect(TabShortcuts.digit(for: keyDown("0", .command)) == 0)
        #expect(TabShortcuts.digit(for: keyDown("0", [.command, .control])) == nil)
        #expect(TabShortcuts.digit(for: keyDown("1", [.command, .shift])) == nil)
        #expect(TabShortcuts.digit(for: keyDown("2", [])) == nil)
        #expect(TabShortcuts.digit(for: keyDown("j", .command)) == nil)
    }
}
