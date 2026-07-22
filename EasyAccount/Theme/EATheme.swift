import SwiftUI

enum EATheme {
    // Dark shell — matching the UX mock
    static let background = Color(red: 10 / 255, green: 12 / 255, blue: 18 / 255)
    static let surface = Color(red: 22 / 255, green: 24 / 255, blue: 32 / 255)
    static let surfaceElevated = Color(red: 32 / 255, green: 34 / 255, blue: 44 / 255)
    static let inputFill = Color(red: 28 / 255, green: 30 / 255, blue: 40 / 255)
    static let label = Color(red: 245 / 255, green: 246 / 255, blue: 250 / 255)
    static let secondary = Color(red: 148 / 255, green: 152 / 255, blue: 168 / 255)
    static let tertiary = Color(red: 98 / 255, green: 102 / 255, blue: 120 / 255)

    static let blue = Color(red: 61 / 255, green: 122 / 255, blue: 255 / 255)
    static let blueDisabled = Color(red: 36 / 255, green: 58 / 255, blue: 110 / 255)
    static let wechatGreen = Color(red: 9 / 255, green: 187 / 255, blue: 85 / 255)
    static let green = Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)
    static let cyan = Color(red: 72 / 255, green: 180 / 255, blue: 220 / 255)
    static let orange = Color(red: 255 / 255, green: 159 / 255, blue: 10 / 255)
    static let danger = Color(red: 255 / 255, green: 69 / 255, blue: 78 / 255)

    /// Kept for older call sites that still reference `card`.
    static let card = surface
}
