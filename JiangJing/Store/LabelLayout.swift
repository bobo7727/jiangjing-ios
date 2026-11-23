import Foundation

/// Where the label sits on the photo.
enum LabelPosition: String, CaseIterable, Sendable {
    case bottomLeft
    case bottomRight
}

/// Pure geometry for the label stamp. All values are in the photo's own pixels.
struct LabelLayout: Equatable, Sendable {
    let fontSize: Double
    let margin: Double
    let padding: Double
    let maxTextWidth: Double
    let cornerRadius: Double

    static let maxCharacters = 40

    static func make(imageWidth: Double, imageHeight: Double) -> LabelLayout {
        let shortSide = max(1, min(imageWidth, imageHeight))
        let fontSize = max(14, (shortSide * 0.04).rounded())
        return LabelLayout(
            fontSize: fontSize,
            margin: (fontSize * 0.9).rounded(),
            padding: (fontSize * 0.5).rounded(),
            maxTextWidth: max(1, imageWidth * 0.8),
            cornerRadius: (fontSize * 0.35).rounded()
        )
    }

    /// Trims, folds line breaks into spaces, and limits the length.
    static func normalized(_ text: String) -> String {
        let folded = text.components(separatedBy: .newlines).joined(separator: " ")
        let trimmed = folded.trimmingCharacters(in: .whitespaces)
        return String(trimmed.prefix(maxCharacters))
    }

    /// Final stamp text: the name, then the date when asked. Empty when there is nothing to stamp.
    static func composed(name: String, date: String?) -> String {
        let clean = normalized(name)
        guard let date, !date.isEmpty else { return clean }
        return clean.isEmpty ? date : clean + " · " + date
    }

    /// Horizontal origin of a label box of `boxWidth` for the given position.
    func originX(position: LabelPosition, imageWidth: Double, boxWidth: Double) -> Double {
        switch position {
        case .bottomLeft: return margin
        case .bottomRight: return max(margin, imageWidth - margin - boxWidth)
        }
    }

    /// Vertical origin of a label box of `boxHeight` measured from the top of the image.
    func originY(imageHeight: Double, boxHeight: Double) -> Double {
        max(margin, imageHeight - margin - boxHeight)
    }
}
