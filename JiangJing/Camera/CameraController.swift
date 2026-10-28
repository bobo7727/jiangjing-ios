import AVFoundation
import Combine
import CoreImage
import CoreMedia
import CoreVideo
import os
import UIKit

enum CameraProblem: Equatable {
    case noCamera
    case noPreview
}

enum SaveState: Equatable {
    case saving
    case saved
    case denied
    case failed
}

struct FrozenPhoto: Identifiable, Equatable {
    let id = UUID()
    let image: UIImage
    let fileURL: URL
    var saveState: SaveState

    static func == (lhs: FrozenPhoto, rhs: FrozenPhoto) -> Bool {
        lhs.id == rhs.id && lhs.saveState == rhs.saveState
    }
}

struct RecordedClip: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let thumbnail: UIImage?
    let duration: TimeInterval
    var saveState: SaveState

    static func == (lhs: RecordedClip, rhs: RecordedClip) -> Bool {
        lhs.id == rhs.id && lhs.saveState == rhs.saveState
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Live magnifier. Zoom is applied on the capture device, so the preview, the
/// still frame, and the recorded movie all show the same magnification.
/// Stills come from the video buffer and are cropped to the on-screen aspect fill.
///
/// Session work runs on `sessionQueue`. `@Published` properties are updated on the main actor.
final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published private(set) var authorization = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var problem: CameraProblem?
    @Published private(set) var isReady = false
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var minZoom: CGFloat = 1
    @Published private(set) var maxZoom: CGFloat = 1
    @Published private(set) var torchLevel: TorchLevel = .off
    @Published private(set) var torchAvailable = false
    @Published private(set) var usesCloseUpCamera = false
    @Published private(set) var audioEnabled = false
    @Published private(set) var isConfiguringAudio = false
    @Published private(set) var canRecord = true
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var isCapturingPhoto = false
    @Published var focusPoint: CGPoint?
    @Published var frozenPhoto: FrozenPhoto?
    @Published var recordedClip: RecordedClip?
    @Published var alert: AppAlert?

    private let sessionQueue = DispatchQueue(label: "app.jiangjing.camera.session")
    private let frameQueue = DispatchQueue(label: "app.jiangjing.camera.frames")
    private let logger = Logger(subsystem: "com.jiangjing.magnifier", category: "camera")
    private let ciContext = CIContext()

    private let videoOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let bufferLock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?
    private var acceptingFrames = false
    private var videoDevice: AVCaptureDevice?
    private var audioInput: AVCaptureDeviceInput?
    private var zoomObservation: NSKeyValueObservation?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var previewSize: CGSize = .zero
    private var isConfigured = false
    private var wantsRunning = false
    private var pinchBaseline: CGFloat = 1
    private var focusToken = 0
    private var readyTimeoutToken = 0
    private var didConfigureCodec = false
    private var didApplyDataRotation = false
    private var subjectAreaObserver: NSObjectProtocol?
    private var ignoreSubjectFocusUntil = Date.distantPast

    deinit {
        zoomObservation?.invalidate()
        if let subjectAreaObserver {
            NotificationCenter.default.removeObserver(subjectAreaObserver)
        }
    }

    func onForeground() {
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
        guard authorization == .authorized else { return }
        scheduleReadyTimeout()
        let zoom = zoomFactor
        let torch = torchLevel
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = true
            self.startIfNeeded(zoom: zoom, torch: torch)
        }
    }

    func onBackground() {
        readyTimeoutToken += 1
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = false
            self.stopIfNeeded()
        }
    }

    func requestCameraAccess() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                self.authorization = AVCaptureDevice.authorizationStatus(for: .video)
                if granted {
                    self.onForeground()
                }
            }
        }
    }

    func restart() {
        problem = nil
        isReady = false
        let zoom = zoomFactor
        let torch = torchLevel
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = true
            if self.session.isRunning {
                self.setAcceptingFrames(false)
                self.session.stopRunning()
            }
            self.tearDownConfiguration()
            self.startIfNeeded(zoom: zoom, torch: torch)
        }
        scheduleReadyTimeout()
    }

    func updatePreviewSize(_ size: CGSize) {
        guard abs(size.width - previewSize.width) > 0.5 || abs(size.height - previewSize.height) > 0.5 else {
            return
        }
        previewSize = size
    }

    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        PortraitRotation.apply(to: layer.connection)
    }

    func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            pinchBaseline = zoomFactor
        case .changed:
            setZoom(pinchBaseline * recognizer.scale, animated: false)
        default:
            break
        }
    }

    func focus(at viewPoint: CGPoint) {
        guard let layer = previewLayer else { return }
        let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: viewPoint)
        guard (0...1).contains(devicePoint.x), (0...1).contains(devicePoint.y) else { return }
        showFocusIndicator(at: viewPoint)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.ignoreSubjectFocusUntil = Date().addingTimeInterval(2)
            self.applyFocus(at: devicePoint)
        }
    }

    func resetZoom() {
        let target = ZoomScale.clamp(1, min: minZoom, max: maxZoom)
        setZoom(target, animated: true)
    }

    func setZoom(_ requested: CGFloat, animated: Bool) {
        let clamped = ZoomScale.clamp(requested, min: minZoom, max: maxZoom)
        zoomFactor = clamped
        sessionQueue.async { [weak self] in
            self?.applyZoom(clamped, animated: animated)
        }
    }

    func cycleTorch() {
        guard torchAvailable else {
            alert = AppAlert(title: L10n.torchUnavailableTitle, message: L10n.torchUnavailableBody)
            return
        }
        let next = torchLevel.next
        torchLevel = next
        sessionQueue.async { [weak self] in
            self?.applyTorch(next)
        }
    }

    func setAudioEnabled(_ enabled: Bool) {
        guard !isRecording, !isConfiguringAudio else { return }
        if !enabled {
            audioEnabled = false
            let zoom = zoomFactor
            let torch = torchLevel
            sessionQueue.async { [weak self] in
                self?.removeAudioInput(zoom: zoom, torch: torch)
            }
            return
        }
        isConfiguringAudio = true
        let zoom = zoomFactor
        let torch = torchLevel
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.isConfiguringAudio = false
                    self.audioEnabled = false
                    self.alert = AppAlert(title: L10n.audioDeniedTitle, message: L10n.audioDeniedBody)
                    return
                }
                self.sessionQueue.async { [weak self] in
                    let added = self?.addAudioInput(zoom: zoom, torch: torch) ?? false
                    Task { @MainActor in
                        self?.isConfiguringAudio = false
                        self?.audioEnabled = added
                        if !added {
                            self?.alert = AppAlert(title: L10n.audioDeniedTitle, message: L10n.audioDeniedBody)
                        }
                    }
                }
            }
        }
    }

    func toggleRecording() {
        if isRecording {
            sessionQueue.async { [weak self] in
                guard let self, self.movieOutput.isRecording else { return }
                self.movieOutput.stopRecording()
            }
            return
        }
        guard isReady, frozenPhoto == nil else { return }
        isRecording = true
        sessionQueue.async { [weak self] in
            self?.beginRecording()
        }
    }

    func capturePhoto() {
        guard isReady, !isRecording, !isCapturingPhoto, frozenPhoto == nil else { return }
        isCapturingPhoto = true
        let size = previewSize
        frameQueue.async { [weak self] in
            guard let self else { return }
            self.bufferLock.lock()
            let buffer = self.latestPixelBuffer
            self.bufferLock.unlock()
            guard let buffer, let rendered = self.render(buffer: buffer, previewSize: size) else {
                Task { @MainActor in
                    self.isCapturingPhoto = false
                    self.alert = AppAlert(title: L10n.captureNotReadyTitle, message: L10n.captureNotReadyBody)
                }
                return
            }
            Task { @MainActor in
                self.isCapturingPhoto = false
                self.frozenPhoto = FrozenPhoto(
                    image: rendered.image,
                    fileURL: rendered.url,
                    saveState: .saving
                )
                await self.saveFrozenPhoto(data: rendered.data)
            }
        }
    }

    func dismissFreeze() {
        FileStore.remove(frozenPhoto?.fileURL)
        frozenPhoto = nil
    }

    func dismissClip() {
        guard let clip = recordedClip else { return }
        recordedClip = nil
        // The photo library may still be reading the file. The save completion deletes it.
        if clip.saveState != .saving {
            FileStore.remove(clip.url)
        }
    }

    // MARK: - Session

    private func startIfNeeded(zoom: CGFloat, torch: TorchLevel) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard wantsRunning else { return }
        if !isConfigured {
            configureSession()
        }
        guard isConfigured else { return }
        // Rotate video-data buffers before startRunning. Doing it later
        // rebuilds the capture pipeline on every frame's connection.
        configureConnections()
        setAcceptingFrames(true)
        if !session.isRunning {
            session.startRunning()
        }
        if !didApplyDataRotation || !didConfigureCodec {
            configureConnections()
        }
        applyZoom(zoom, animated: false)
        applyTorch(torch)
        let running = session.isRunning
        Task { @MainActor in
            if !running, self.problem == nil {
                self.problem = .noPreview
            }
        }
    }

    private func stopIfNeeded() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        setAcceptingFrames(false)
        clearLatestBuffer()
        if movieOutput.isRecording {
            movieOutput.stopRecording()
            return
        }
        if session.isRunning {
            session.stopRunning()
        }
    }

    private func configureSession() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let (device, input) = makeVideoInput(), session.canAddInput(input) else {
            session.commitConfiguration()
            publishProblem(.noCamera)
            return
        }
        session.addInput(input)
        videoDevice = device
        observeZoom(on: device)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        let pixelFormat: [String: Any] = [
            kCVPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.videoSettings = pixelFormat
        videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            tearDownConfiguration()
            publishProblem(.noCamera)
            return
        }
        session.addOutput(videoOutput)

        let movieAdded = session.canAddOutput(movieOutput)
        if movieAdded {
            session.addOutput(movieOutput)
        }

        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        }

        session.commitConfiguration()
        configureDevice(device)
        isConfigured = true

        let closeUp = deviceSupportsCloseFocus(device)
        let hasTorch = device.hasTorch
        logger.info("Camera \(device.deviceType.rawValue, privacy: .public) closeUp=\(closeUp ? "yes" : "no", privacy: .public)")
        Task { @MainActor in
            self.usesCloseUpCamera = closeUp
            self.torchAvailable = hasTorch
            self.canRecord = movieAdded
            self.problem = nil
        }
    }

    private func tearDownConfiguration() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        removeAllCaptureHardware()
        zoomObservation?.invalidate()
        zoomObservation = nil
        if let subjectAreaObserver {
            NotificationCenter.default.removeObserver(subjectAreaObserver)
            self.subjectAreaObserver = nil
        }
        videoDevice = nil
        audioInput = nil
        isConfigured = false
        didConfigureCodec = false
        didApplyDataRotation = false
        clearLatestBuffer()
    }

    private func removeAllCaptureHardware() {
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
    }

    /// Prefer the virtual multi-camera that includes the ultra-wide lens.
    /// On Pro phones that device switches to the macro camera when the subject is very close.
    private func makeVideoInput() -> (AVCaptureDevice, AVCaptureDeviceInput)? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInWideAngleCamera,
            .builtInUltraWideCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .back
        )
        for type in types {
            guard let device = discovery.devices.first(where: { $0.deviceType == type }) else { continue }
            if let input = try? AVCaptureDeviceInput(device: device) {
                return (device, input)
            }
        }
        return nil
    }

    private func deviceSupportsCloseFocus(_ device: AVCaptureDevice) -> Bool {
        if device.deviceType == .builtInUltraWideCamera { return true }
        guard device.isVirtualDevice else { return false }
        return device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
    }

    private func configureDevice(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = true
            }
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .none
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
            if device.isGeometricDistortionCorrectionSupported {
                device.geometricDistortionCorrectionEnabled = true
            }
            if device.isVirtualDevice,
               device.activePrimaryConstituentDeviceSwitchingBehavior != .unsupported {
                device.setPrimaryConstituentDeviceSwitchingBehavior(
                    .auto,
                    restrictedSwitchingBehaviorConditions: []
                )
            }

            let range = zoomRange(for: device)
            let initial = ZoomScale.clamp(1, min: range.min, max: range.max)
            device.videoZoomFactor = initial
            Task { @MainActor in
                self.minZoom = range.min
                self.maxZoom = range.max
                self.zoomFactor = initial
            }
            observeSubjectAreaChanges(for: device)
        } catch {
            logger.error("Device configuration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func observeSubjectAreaChanges(for device: AVCaptureDevice) {
        if let subjectAreaObserver {
            NotificationCenter.default.removeObserver(subjectAreaObserver)
        }
        subjectAreaObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.subjectAreaDidChangeNotification,
            object: device,
            queue: nil
        ) { [weak self] _ in
            self?.sessionQueue.async { [weak self] in
                guard let self, Date() > self.ignoreSubjectFocusUntil else { return }
                self.ignoreSubjectFocusUntil = Date().addingTimeInterval(1)
                self.applyFocus(at: CGPoint(x: 0.5, y: 0.5))
            }
        }
    }

    private func configureConnections() {
        if !didApplyDataRotation, videoOutput.connection(with: .video) != nil {
            PortraitRotation.apply(to: videoOutput.connection(with: .video))
            didApplyDataRotation = true
        }
        PortraitRotation.apply(to: movieOutput.connection(with: .video))
        if let connection = movieOutput.connection(with: .video), connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .auto
        }
        if !didConfigureCodec,
           let connection = movieOutput.connection(with: .video),
           movieOutput.availableVideoCodecTypes.contains(.h264) {
            let codecSettings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264]
            movieOutput.setOutputSettings(codecSettings, for: connection)
            didConfigureCodec = true
        }
        Task { @MainActor in
            PortraitRotation.apply(to: self.previewLayer?.connection)
        }
    }

    private func zoomRange(for device: AVCaptureDevice) -> (min: CGFloat, max: CGFloat) {
        let lower = device.minAvailableVideoZoomFactor
        let upper = min(device.maxAvailableVideoZoomFactor, MagnifierConfig.zoomCap)
        return (lower, max(upper, lower))
    }

    private func observeZoom(on device: AVCaptureDevice) {
        zoomObservation = device.observe(\.videoZoomFactor, options: [.new]) { [weak self] device, _ in
            let factor = device.videoZoomFactor
            Task { @MainActor in
                self?.zoomFactor = factor
            }
        }
    }

    private func applyZoom(_ factor: CGFloat, animated: Bool) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard let device = videoDevice else { return }
        let range = zoomRange(for: device)
        let clamped = ZoomScale.clamp(factor, min: range.min, max: range.max)
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if animated, abs(device.videoZoomFactor - clamped) > 0.02 {
                device.ramp(toVideoZoomFactor: clamped, withRate: MagnifierConfig.zoomRampRate)
            } else {
                device.cancelVideoZoomRamp()
                device.videoZoomFactor = clamped
            }
        } catch {
            logger.error("Zoom failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyTorch(_ level: TorchLevel) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard let device = videoDevice, device.hasTorch else {
            Task { @MainActor in self.torchAvailable = false }
            return
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if level == .off {
                if device.isTorchAvailable {
                    device.torchMode = .off
                }
                return
            }
            guard device.isTorchAvailable else {
                Task { @MainActor in
                    self.torchLevel = .off
                    self.alert = AppAlert(title: L10n.torchUnavailableTitle, message: L10n.torchUnavailableBody)
                }
                return
            }
            let brightness = min(level.brightness, AVCaptureDevice.maxAvailableTorchLevel)
            try device.setTorchModeOn(level: brightness)
        } catch {
            logger.error("Torch failed: \(error.localizedDescription, privacy: .public)")
            Task { @MainActor in
                self.torchLevel = .off
                self.alert = AppAlert(title: L10n.torchUnavailableTitle, message: L10n.torchUnavailableBody)
            }
        }
    }

    private func applyFocus(at devicePoint: CGPoint) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard let device = videoDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = devicePoint
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            } else if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = devicePoint
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
        } catch {
            logger.error("Focus failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func addAudioInput(zoom: CGFloat, torch: TorchLevel) -> Bool {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        if audioInput != nil { return true }
        guard let microphone = AVCaptureDevice.default(for: .audio) else { return false }
        do {
            let input = try AVCaptureDeviceInput(device: microphone)
            session.beginConfiguration()
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                return false
            }
            session.addInput(input)
            session.commitConfiguration()
            audioInput = input
            applyZoom(zoom, animated: false)
            applyTorch(torch)
            return true
        } catch {
            logger.error("Microphone failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func removeAudioInput(zoom: CGFloat, torch: TorchLevel) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard let audioInput else { return }
        session.beginConfiguration()
        session.removeInput(audioInput)
        session.commitConfiguration()
        self.audioInput = nil
        applyZoom(zoom, animated: false)
        applyTorch(torch)
    }

    private func beginRecording() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard !movieOutput.isRecording else { return }
        guard session.outputs.contains(where: { $0 === movieOutput }) else {
            Task { @MainActor in
                self.isRecording = false
                self.alert = AppAlert(title: L10n.recordFailedTitle, message: L10n.recordFailedBody)
            }
            return
        }
        PortraitRotation.apply(to: movieOutput.connection(with: .video))
        let url = FileStore.makeURL(ext: "mov")
        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    private func setAcceptingFrames(_ accepting: Bool) {
        bufferLock.lock()
        acceptingFrames = accepting
        if !accepting {
            latestPixelBuffer = nil
        }
        bufferLock.unlock()
    }

    private func clearLatestBuffer() {
        bufferLock.lock()
        latestPixelBuffer = nil
        bufferLock.unlock()
    }

    private func publishProblem(_ problem: CameraProblem) {
        Task { @MainActor in
            self.problem = problem
        }
    }

    private func scheduleReadyTimeout() {
        readyTimeoutToken += 1
        let token = readyTimeoutToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(MagnifierConfig.readyTimeout * 1_000_000_000.0))
            guard self.readyTimeoutToken == token, !self.isReady, self.authorization == .authorized else { return }
            if self.problem == nil {
                self.problem = .noPreview
            }
        }
    }

    private func showFocusIndicator(at point: CGPoint) {
        focusToken += 1
        let token = focusToken
        focusPoint = point
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(MagnifierConfig.focusIndicatorDuration * 1_000_000_000.0))
            guard self.focusToken == token else { return }
            self.focusPoint = nil
        }
    }

    // MARK: - Still image

    private func render(buffer: CVPixelBuffer, previewSize: CGSize) -> (image: UIImage, data: Data, url: URL)? {
        var image = CIImage(cvPixelBuffer: buffer)
        // Portrait rotation is requested on the connection. If a device still
        // delivers a landscape buffer, rotate the back camera upright.
        if image.extent.width > image.extent.height {
            image = image.oriented(.right)
        }
        if image.extent.origin != .zero {
            image = image.transformed(by: CGAffineTransform(
                translationX: -image.extent.origin.x,
                y: -image.extent.origin.y
            ))
        }
        var crop = ZoomScale.aspectFillCrop(imageSize: image.extent.size, viewSize: previewSize)
        crop = crop.intersection(image.extent)
        guard crop.width > 2, crop.height > 2 else { return nil }
        image = image.cropped(to: crop).transformed(by: CGAffineTransform(
            translationX: -crop.origin.x,
            y: -crop.origin.y
        ))
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return nil }
        let uiImage = UIImage(cgImage: cgImage)
        guard let data = uiImage.jpegData(compressionQuality: MagnifierConfig.jpegQuality) else { return nil }
        let url = FileStore.makeURL(ext: "jpg")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Could not write JPEG: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return (uiImage, data, url)
    }

    private func saveFrozenPhoto(data: Data) async {
        let state = await saveState {
            try await PhotoLibrarySaver.saveImageData(data)
        }
        await MainActor.run {
            guard var photo = self.frozenPhoto else { return }
            photo.saveState = state
            self.frozenPhoto = photo
        }
    }

    private func saveRecordedVideo(at url: URL) async {
        let state = await saveState {
            try await PhotoLibrarySaver.saveVideo(at: url)
        }
        await MainActor.run {
            guard self.recordedClip?.url == url, var clip = self.recordedClip else {
                FileStore.remove(url)
                return
            }
            clip.saveState = state
            self.recordedClip = clip
        }
    }

    private func saveState(_ operation: () async throws -> Void) async -> SaveState {
        do {
            try await operation()
            return .saved
        } catch let error as SaveError where error == .denied {
            return .denied
        } catch {
            logger.error("Photo library save failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    private func thumbnail(for url: URL) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let image = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return UIImage(cgImage: image)
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        bufferLock.lock()
        let accept = acceptingFrames
        if accept {
            latestPixelBuffer = buffer
        }
        bufferLock.unlock()
        guard accept else { return }
        Task { @MainActor in
            if !self.isReady {
                self.isReady = true
                self.problem = nil
                self.readyTimeoutToken += 1
            }
        }
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        Task { @MainActor in
            self.isRecording = true
            self.recordingStartedAt = Date()
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let nsError = error as NSError?
        let finishedFlag = nsError?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool
        let usable = error == nil || finishedFlag == true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let shouldStop = !self.wantsRunning
            if shouldStop, self.session.isRunning {
                self.setAcceptingFrames(false)
                self.session.stopRunning()
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let preview = usable ? self.thumbnail(for: outputFileURL) : nil
                let bytes = (try? FileManager.default.attributesOfItem(atPath: outputFileURL.path))?[.size] as? NSNumber
                Task { @MainActor in
                    let duration = self.recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                    self.isRecording = false
                    self.recordingStartedAt = nil
                    guard usable, (bytes?.intValue ?? 0) > 0 else {
                        FileStore.remove(outputFileURL)
                        self.alert = AppAlert(title: L10n.recordFailedTitle, message: L10n.recordFailedBody)
                        return
                    }
                    if let previous = self.recordedClip, previous.url != outputFileURL, previous.saveState != .saving {
                        FileStore.remove(previous.url)
                    }
                    self.recordedClip = RecordedClip(
                        url: outputFileURL,
                        thumbnail: preview,
                        duration: duration,
                        saveState: .saving
                    )
                    await self.saveRecordedVideo(at: outputFileURL)
                }
            }
        }
    }
}
