import CoreGraphics
import Foundation

/// Logarithmic zoom mapping so the low end of the slider stays usable.
enum ZoomScale {
    static func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, minValue), maxValue)
    }

    static func factor(forSlider t: Double, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        let clampedT = Swift.min(Swift.max(t, 0), 1)
        let lower = Swift.max(Double(minValue), 0.01)
        let upper = Swift.max(Double(maxValue), lower)
        let mapped = exp(log(lower) + (log(upper) - log(lower)) * clampedT)
        return CGFloat(mapped)
    }

    static func sliderPosition(for factor: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> Double {
        let lower = Swift.max(Double(minValue), 0.01)
        let upper = Swift.max(Double(maxValue), lower)
        let value = Swift.min(Swift.max(Double(factor), lower), upper)
        let span = log(upper) - log(lower)
        if abs(span) < 0.000_001 { return 0 }
        return (log(value) - log(lower)) / span
    }

    /// Center crop that matches `AVLayerVideoGravity.resizeAspectFill`.
    static func aspectFillCrop(imageSize: CGSize, viewSize: CGSize) -> CGRect {
        guard imageSize.width > 1, imageSize.height > 1, viewSize.width > 1, viewSize.height > 1 else {
            return CGRect(origin: .zero, size: imageSize)
        }
        let imageAspect = imageSize.width / imageSize.height
        let viewAspect = viewSize.width / viewSize.height
        if imageAspect > viewAspect {
            let width = imageSize.height * viewAspect
            let x = (imageSize.width - width) / 2
            return CGRect(x: x, y: 0, width: width, height: imageSize.height)
        }
        let height = imageSize.width / viewAspect
        let y = (imageSize.height - height) / 2
        return CGRect(x: 0, y: y, width: imageSize.width, height: height)
    }

    static func format(_ factor: CGFloat) -> String {
        let tenths = (factor * 10).rounded() / 10
        if abs(tenths - tenths.rounded()) < 0.05 {
            return String(format: "%.0f×", tenths)
        }
        return String(format: "%.1f×", tenths)
    }

    /// Quick-jump stops. Always includes the widest factor the device allows.
    static func presets(min minZoom: CGFloat, max maxZoom: CGFloat) -> [CGFloat] {
        var factors = [minZoom]
        for candidate in [CGFloat(1), 2, 4, 8] where candidate <= maxZoom + 0.001 && candidate > minZoom + 0.05 {
            factors.append(candidate)
        }
        return factors
    }

    static func matches(_ factor: CGFloat, preset: CGFloat) -> Bool {
        abs(factor - preset) <= max(0.08, preset * 0.06)
    }
}
