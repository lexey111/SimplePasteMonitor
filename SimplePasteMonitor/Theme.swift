import AppKit
import SwiftUI

/// The widget's colors for one appearance.
///
/// Light is its own set, not dark inverted: the dark accents — bright yellow,
/// light green — all but vanish on a light background (system yellow is
/// under 2:1 on it). Each light accent is the lightest step of its hue that
/// reaches 4.5:1 against the light background, the contrast small text needs.
struct Theme {
    let background: Color
    let stroke: Color
    /// Base for text and glyphs, used at reduced opacity for secondary ink.
    let ink: Color
    /// "Here and fine" — status dot, the current history row.
    let green: Color
    /// "On its way" — receiving, the Ask banner.
    let yellow: Color
    /// "Look at this" — an armed history row, unreadable data.
    let orange: Color

    static let dark = Theme(
        background: Color(white: 0.12, opacity: 0.92),
        stroke: .white.opacity(0.08),
        ink: .white,
        green: Color(rgb: 0x1DB954),
        yellow: .yellow,
        orange: .orange
    )

    // Measured against #f7f7f7: 4.68, 4.60, 4.83 : 1.
    static let light = Theme(
        background: Color(white: 0.97, opacity: 0.94),
        stroke: .black.opacity(0.10),
        ink: .black,
        green: Color(rgb: 0x15803D),
        yellow: Color(rgb: 0xA16207),
        orange: Color(rgb: 0xC2410C)
    )

    static func of(_ scheme: ColorScheme) -> Theme { scheme == .dark ? dark : light }
}

/// The user's choice in the menu bar: follow macOS, or pin one.
enum AppearanceSetting: String, CaseIterable {
    case system, light, dark

    static let key = "appearance"

    static var current: AppearanceSetting {
        UserDefaults.standard.string(forKey: key).flatMap(AppearanceSetting.init) ?? .system
    }

    var title: String {
        switch self {
        case .system: return "Same as macOS"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// Nil follows the system — and keeps following it when it switches,
    /// e.g. on an automatic light/dark schedule.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}
