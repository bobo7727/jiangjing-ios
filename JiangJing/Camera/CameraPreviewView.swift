import AVFoundation
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    var focusPoint: CGPoint?
    var onPinch: (UIPinchGestureRecognizer) -> Void
    var onTap: (CGPoint) -> Void
    var onDoubleTap: () -> Void
    var onLayout: (CGSize) -> Void
    var onLayerReady: (AVCaptureVideoPreviewLayer) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PreviewSurface {
        let view = PreviewSurface()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = true
        return view
    }

    func updateUIView(_ uiView: PreviewSurface, context: Context) {
        uiView.onPinch = onPinch
        uiView.onTap = onTap
        uiView.onDoubleTap = onDoubleTap
        uiView.onLayout = onLayout
        uiView.updateFocus(focusPoint)
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        if !context.coordinator.didReportLayer {
            context.coordinator.didReportLayer = true
            onLayerReady(uiView.previewLayer)
        }
    }

    final class Coordinator {
        var didReportLayer = false
    }
}

final class PreviewSurface: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let preview = layer as? AVCaptureVideoPreviewLayer else {
            fatalError("PreviewSurface.layerClass must be AVCaptureVideoPreviewLayer")
        }
        return preview
    }

    var onPinch: ((UIPinchGestureRecognizer) -> Void)?
    var onTap: ((CGPoint) -> Void)?
    var onDoubleTap: (() -> Void)?
    var onLayout: ((CGSize) -> Void)?

    private let pinchRecognizer = UIPinchGestureRecognizer()
    private let tapRecognizer = UITapGestureRecognizer()
    private let doubleTapRecognizer = UITapGestureRecognizer()
    private let focusRing = UIView(frame: CGRect(x: 0, y: 0, width: 78, height: 78))
    private var displayedFocus: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        pinchRecognizer.addTarget(self, action: #selector(pinched(_:)))
        tapRecognizer.addTarget(self, action: #selector(tapped(_:)))
        doubleTapRecognizer.addTarget(self, action: #selector(doubleTapped))
        tapRecognizer.numberOfTapsRequired = 1
        doubleTapRecognizer.numberOfTapsRequired = 2
        tapRecognizer.require(toFail: doubleTapRecognizer)
        addGestureRecognizer(pinchRecognizer)
        addGestureRecognizer(tapRecognizer)
        addGestureRecognizer(doubleTapRecognizer)

        focusRing.isUserInteractionEnabled = false
        focusRing.layer.borderWidth = 2
        focusRing.layer.borderColor = UIColor(red: 0.90, green: 0.63, blue: 0.29, alpha: 1).cgColor
        focusRing.layer.cornerRadius = 39
        focusRing.alpha = 0
        addSubview(focusRing)
    }

    func updateFocus(_ point: CGPoint?) {
        guard point != displayedFocus else { return }
        displayedFocus = point
        guard let point else {
            UIView.animate(withDuration: 0.2) { self.focusRing.alpha = 0 }
            return
        }
        focusRing.center = point
        focusRing.alpha = 1
        focusRing.transform = CGAffineTransform(scaleX: 1.2, y: 1.2)
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.focusRing.transform = .identity
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(bounds.size)
        PortraitRotation.apply(to: previewLayer.connection)
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        onPinch?(recognizer)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        onTap?(recognizer.location(in: self))
    }

    @objc private func doubleTapped() {
        onDoubleTap?()
    }
}
