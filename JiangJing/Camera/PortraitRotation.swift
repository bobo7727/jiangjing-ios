import AVFoundation

/// The phone is often held face-up over a bench. Device orientation is unreliable
/// in that pose (`faceUp`), so the interface stays portrait and the buffer is
/// rotated to match the home indicator, not the gravity vector.
enum PortraitRotation {
    static func apply(to connection: AVCaptureConnection?) {
        guard let connection else { return }
        if #available(iOS 17.0, *) {
            let angle: CGFloat = 90
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        } else {
            applyLegacyPortrait(connection)
        }
    }

    @available(iOS, introduced: 16.0, deprecated: 17.0)
    private static func applyLegacyPortrait(_ connection: AVCaptureConnection) {
        guard connection.isVideoOrientationSupported else { return }
        connection.videoOrientation = .portrait
    }
}
