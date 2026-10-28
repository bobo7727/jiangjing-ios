import UIKit

enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func shutter() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
