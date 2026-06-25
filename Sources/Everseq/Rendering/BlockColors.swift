import AppKit

/// The named background colors a block can carry via `background-color:: <name>`
/// (Logseq-style colored blocks). Stored as the name in the file so the tint stays
/// portable and adapts per light/dark appearance; rendered as a soft rounded box
/// behind the block's content (see `OutlineRowCell`).
enum BlockColor: String, CaseIterable {
    case gray, red, orange, yellow, green, blue, purple, pink

    static let propertyKey = "background-color"

    var displayName: String { rawValue.capitalized }

    /// Soft fill drawn behind the block — light pastel in Aqua, muted in dark.
    var background: NSColor {
        switch self {
        case .gray:   return .dynamic(light: 0xECECEE, dark: 0x3A3A3D)
        case .red:    return .dynamic(light: 0xFCE4E4, dark: 0x4A2A2C)
        case .orange: return .dynamic(light: 0xFCEBD8, dark: 0x4A3620)
        case .yellow: return .dynamic(light: 0xFBF3CE, dark: 0x453B1C)
        case .green:  return .dynamic(light: 0xDFF1E0, dark: 0x213A29)
        case .blue:   return .dynamic(light: 0xDCEBFB, dark: 0x1F3450)
        case .purple: return .dynamic(light: 0xEBE2FA, dark: 0x342A4D)
        case .pink:   return .dynamic(light: 0xFBE2EF, dark: 0x47263A)
        }
    }

    /// Saturated dot shown next to the color's menu item.
    var swatch: NSColor {
        switch self {
        case .gray:   return .systemGray
        case .red:    return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green:  return .systemGreen
        case .blue:   return .systemBlue
        case .purple: return .systemPurple
        case .pink:   return .systemPink
        }
    }
}

private extension NSColor {
    /// Appearance-adaptive color from two 0xRRGGBB hex values.
    static func dynamic(light: Int, dark: Int) -> NSColor {
        func make(_ hex: Int) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? make(dark) : make(light)
        }
    }
}
