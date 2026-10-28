import CoreGraphics
import SwiftUI

/// Tunables for the magnifier. Zoom above the cap is digital and gets soft quickly,
/// so the slider stops here even if the device reports a higher maximum.
enum MagnifierConfig {
    static let zoomCap: CGFloat = 15
    static let readyTimeout: TimeInterval = 8
    static let hintVisibleDuration: TimeInterval = 6
    static let focusIndicatorDuration: TimeInterval = 1.2
    static let jpegQuality: CGFloat = 0.92
    static let zoomRampRate: Float = 5
}

enum TorchLevel: Int, CaseIterable, Equatable {
    case off
    case low
    case medium
    case high

    /// `AVCaptureDevice.setTorchModeOn(level:)` requires a value in (0, 1].
    var brightness: Float {
        switch self {
        case .off: return 0
        case .low: return 0.25
        case .medium: return 0.6
        case .high: return 1
        }
    }

    var title: String {
        switch self {
        case .off: return L10n.torchOff
        case .low: return L10n.torchLow
        case .medium: return L10n.torchMedium
        case .high: return L10n.torchHigh
        }
    }

    var symbolName: String {
        self == .off ? "flashlight.off.fill" : "flashlight.on.fill"
    }

    var next: TorchLevel {
        TorchLevel(rawValue: rawValue + 1) ?? .off
    }
}

enum CraftColor {
    static let amber = Color(red: 0.90, green: 0.63, blue: 0.29)
    static let ink = Color(red: 0.07, green: 0.06, blue: 0.05)
}

enum ClockFormat {
    static func string(from interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
