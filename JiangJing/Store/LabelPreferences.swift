import Foundation

/// What the user typed for the label stamp. Stored only on this device (UserDefaults, app-only preferences).
struct LabelStyle: Equatable, Sendable {
    var name: String = ""
    var showDate: Bool = false
    var position: LabelPosition = .bottomLeft

    /// Final stamp text; empty when there is nothing to stamp.
    func stampText(date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard showDate else { return LabelLayout.composed(name: name, date: nil) }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return LabelLayout.composed(name: name, date: formatter.string(from: date))
    }
}

enum LabelPreferences {
    private static let nameKey = "label.name"
    private static let dateKey = "label.showDate"
    private static let positionKey = "label.position"

    static func load(_ defaults: UserDefaults = .standard) -> LabelStyle {
        LabelStyle(
            name: LabelLayout.normalized(defaults.string(forKey: nameKey) ?? ""),
            showDate: defaults.bool(forKey: dateKey),
            position: defaults.string(forKey: positionKey).flatMap(LabelPosition.init(rawValue:)) ?? .bottomLeft
        )
    }

    static func save(_ style: LabelStyle, _ defaults: UserDefaults = .standard) {
        defaults.set(LabelLayout.normalized(style.name), forKey: nameKey)
        defaults.set(style.showDate, forKey: dateKey)
        defaults.set(style.position.rawValue, forKey: positionKey)
    }
}
