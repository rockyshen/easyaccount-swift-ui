import Foundation

enum MoneyFormat {
    private static let displayFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()

    private static let apiFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func decimal(from raw: String?) -> Decimal {
        guard let raw else { return 0 }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }

    static func display(_ raw: String?) -> String {
        let value = decimal(from: raw) as NSDecimalNumber
        return displayFormatter.string(from: value) ?? "0.00"
    }

    /// 提交给后端的金额字符串（两位小数）。
    static func apiString(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.replacingOccurrences(of: ",", with: "")
        guard let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        var rounded = value
        var result = Decimal()
        NSDecimalRound(&result, &rounded, 2, .plain)
        return apiFormatter.string(from: result as NSDecimalNumber)
    }

    /// percent 可能是 "100" 或 "100%"，返回 0...1 供进度条使用。
    static func percentFraction(from raw: String?) -> CGFloat {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return 0
        }
        if text.hasSuffix("%") { text.removeLast() }
        guard let value = Double(text) else { return 0 }
        return CGFloat(min(max(value / 100, 0), 1))
    }
}
