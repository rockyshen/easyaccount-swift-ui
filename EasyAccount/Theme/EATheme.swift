import SwiftUI
import UIKit

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "系统"
        case .light: return "浅色"
        case .dark: return "暗色"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum EATheme {
    static let background = dynamic(
        light: rgb(245, 246, 250),
        dark: rgb(10, 12, 18)
    )
    static let surface = dynamic(
        light: rgb(255, 255, 255),
        dark: rgb(22, 24, 32)
    )
    static let surfaceElevated = dynamic(
        light: rgb(236, 238, 245),
        dark: rgb(32, 34, 44)
    )
    static let inputFill = dynamic(
        light: rgb(240, 242, 247),
        dark: rgb(28, 30, 40)
    )
    static let label = dynamic(
        light: rgb(28, 28, 30),
        dark: rgb(245, 246, 250)
    )
    static let secondary = dynamic(
        light: rgb(110, 114, 128),
        dark: rgb(148, 152, 168)
    )
    static let tertiary = dynamic(
        light: rgb(158, 162, 176),
        dark: rgb(98, 102, 120)
    )

    static let blue = dynamic(
        light: rgb(37, 99, 235),
        dark: rgb(61, 122, 255)
    )
    static let blueDisabled = dynamic(
        light: rgb(163, 191, 250),
        dark: rgb(36, 58, 110)
    )
    static let wechatGreen = Color(red: 9 / 255, green: 187 / 255, blue: 85 / 255)
    static let green = Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)
    static let cyan = dynamic(
        light: rgb(14, 165, 190),
        dark: rgb(72, 180, 220)
    )
    static let orange = Color(red: 255 / 255, green: 159 / 255, blue: 10 / 255)
    static let danger = dynamic(
        light: rgb(215, 0, 21),
        dark: rgb(255, 69, 78)
    )

    /// 玻璃按钮三件套：半透明填充叠在 Material 之上，配细高光描边与柔和投影。
    /// 浅/深色下都呈现「比背景略亮的半透明圆」，以此保持两种模式观感一致。
    static let glassFill = dynamic(
        light: UIColor(white: 1, alpha: 0.45),
        dark: UIColor(white: 1, alpha: 0.10)
    )
    static let glassStroke = dynamic(
        light: UIColor(white: 1, alpha: 0.90),
        dark: UIColor(white: 1, alpha: 0.16)
    )
    static let glassShadow = dynamic(
        light: UIColor(white: 0, alpha: 0.08),
        dark: UIColor(white: 0, alpha: 0.30)
    )

    static let scrim = dynamic(
        light: UIColor(white: 0, alpha: 0.28),
        dark: UIColor(white: 0, alpha: 0.45)
    )
    static let toastShadow = dynamic(
        light: UIColor(white: 0, alpha: 0.12),
        dark: UIColor(white: 0, alpha: 0.35)
    )

    /// Kept for older call sites that still reference `card`.
    static let card = surface

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, alpha: CGFloat = 1) -> UIColor {
        UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: alpha)
    }

    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}
