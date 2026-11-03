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

struct FrozenPhoto: Identifiable, Equatable {
    let id: UUID
    let image: UIImage
    let fileURL: URL

    static func == (lhs: FrozenPhoto, rhs: FrozenPhoto) -> Bool {
        lhs.id == rhs.id
    }
}

struct RecordedClip: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let thumbnail: UIImage?
    let duration: TimeInterval

    static func == (lhs: RecordedClip, rhs: RecordedClip) -> Bool {
        lhs.id == rhs.id
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

    @MainActor @Published private(set) var authorization = AVCaptureDevice.authorizationStatus(for: .video)
    @MainActor @Published private(set) var problem: CameraProblem?
    @MainActor @Published private(set) var capture = CaptureState()
    @MainActor var isReady: Bool { capture.ready }
    @MainActor var isRecording: Bool { capture.isRecording }
    @MainActor var isCapturingPhoto: Bool { capture.phase == .photo }
    @MainActor let media: MediaLibraryModel
    @MainActor private var mediaChanges: AnyCancellable?
    @MainActor @Published private(set) var zoomFactor: CGFloat = 1
    @MainActor @Published private(set) var minZoom: CGFloat = 1
    @MainActor @Published private(set) var maxZoom: CGFloat = 1
    @MainActor @Published private(set) var torchLevel: TorchLevel = .off
    @MainActor @Published private(set) var torchAvailable = false
    @MainActor @Published private(set) var usesCloseUpCamera = false
    @MainActor @Published private(set) var audioEnabled = false
    @MainActor @Published private(set) var isConfiguringAudio = false
    @MainActor @Published private(set) var canRecord = true
    @MainActor @Published private(set) var recordingStartedAt: Date?
    @MainActor @Published var focusPoint: CGPoint?
    @MainActor @Published var frozenPhoto: FrozenPhoto?
    @MainActor @Published var recordedClip: RecordedClip?
    @MainActor @Published var alert: AppAlert?

    private let sessionQueue = DispatchQueue(label: "app.jiangjing.camera.session")
    private let frameQueue = DispatchQueue(label: "app.jiangjing.camera.frames")
    private let logger = Logger(subsystem: "com.jiangjing.magnifier", category: "camera")
    private let ciContext = CIContext()

    private let videoOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let bufferLock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?
    // These three fields and latestPixelBuffer are protected by bufferLock.
    private var acceptingFrames = false
    private var frameGeneration = UUID()
    private var didReportFirstFrame = false
    // sessionQueue only, including delegate handling forwarded to that queue.
    private var sessionGeneration = UUID()
    private var audioPreference = AudioPreference()
    private var recordingStopRequested = false
    private var recordingURL: URL?
    private var pendingRebuild: (UUID, CGFloat, TorchLevel)?
    @MainActor private var foreground = false
    @MainActor private var interactive = false
    @MainActor private var needsSessionRecovery = false
    @MainActor private var audioRequest = UUID()
    @MainActor private var activeRecording: MediaRecord?
    @MainActor private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @MainActor private let sessionObservers = NotificationBag()

    @MainActor init(library: MediaLibraryModel) {
        media = library
        super.init()
        mediaChanges = library.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
    private var videoDevice: AVCaptureDevice?
    private var audioInput: AVCaptureDeviceInput?
    private var zoomObservation: NSKeyValueObservation?
    private var torchObservations: [NSKeyValueObservation] = []
    private var requestedTorch: TorchLevel = .off
    @MainActor private weak var previewLayer: AVCaptureVideoPreviewLayer?
    @MainActor private var previewSize: CGSize = .zero
    private var isConfigured = false
    private var wantsRunning = false
    @MainActor private var pinchBaseline: CGFloat = 1
    @MainActor private var focusToken = 0
    @MainActor private var readyTimeoutToken = 0
    private var didConfigureCodec = false
    private var didApplyDataRotation = false
    private var subjectAreaObserver: NSObjectProtocol?
    private var ignoreSubjectFocusUntil = Date.distantPast

    deinit {
        zoomObservation?.invalidate()
        torchObservations.forEach { $0.invalidate() }
        if let subjectAreaObserver {
            NotificationCenter.default.removeObserver(subjectAreaObserver)
        }
    }

    @MainActor func onForeground() {
        interactive = true
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
        Task { await media.resumePending() }
        if foreground && needsSessionRecovery {
            needsSessionRecovery = false
            restart()
        }
        guard authorization == .authorized, !foreground else { return }
        foreground = true
        problem = nil
        let token = capture.resume()
        installSessionObservers(generation: token)
        scheduleReadyTimeout()
        let zoom = zoomFactor
        let torch = torchLevel
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = true
            self.sessionGeneration = token
            self.startIfNeeded(zoom: zoom, torch: torch)
        }
    }

    /// Transient inactive (permission sheets, Control Center) blocks new capture
    /// and authorizations but does not tear down an otherwise running session.
    @MainActor func onInactive() { interactive = false }

    @MainActor func onBackground() {
        interactive = false
        foreground = false
        audioRequest = UUID()
        isConfiguringAudio = false
        readyTimeoutToken += 1
        capture.suspend()
        // Must precede the asynchronous stop, including a recorder still starting.
        if isRecording || isCapturingPhoto || media.records.contains(where: { $0.saveState == .saving }) {
            beginBackgroundTask()
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = false
            self.stopIfNeeded()
        }
    }

    @MainActor func requestCameraAccess() {
        let request = capture.generation
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                guard let self, self.capture.generation == request else { return }
                self.authorization = AVCaptureDevice.authorizationStatus(for: .video)
                if granted, self.interactive { self.onForeground() }
            }
        }
    }

    @MainActor func restart() {
        guard foreground, interactive else { return }
        problem = nil
        needsSessionRecovery = false
        audioRequest = UUID()
        isConfiguringAudio = false
        let token = capture.invalidate()
        capture.requestStop()
        installSessionObservers(generation: token)
        let zoom = zoomFactor
        let torch = torchLevel
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.sessionGeneration = token
            self.setAcceptingFrames(false)
            // Reconfiguration must wait for the movie's finish callback.
            if self.recordingURL != nil {
                self.pendingRebuild = (token, zoom, torch)
                self.requestRecordingStop()
            } else {
                self.rebuild(generation: token, zoom: zoom, torch: torch)
            }
        }
        scheduleReadyTimeout()
    }

    @MainActor private func installSessionObservers(generation: UUID) {
        sessionObservers.clear()
        for name in [AVCaptureSession.wasInterruptedNotification,
                     AVCaptureSession.interruptionEndedNotification,
                     AVCaptureSession.runtimeErrorNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: session, queue: .main) { [weak self] note in
                let isReset = (note.userInfo?[AVCaptureSessionErrorKey] as? AVError)?.code == .mediaServicesWereReset
                Task { @MainActor in
                    guard let self, self.foreground, self.capture.generation == generation else { return }
                    if name == AVCaptureSession.interruptionEndedNotification || isReset {
                        if self.interactive { self.restart() }
                        else { self.needsSessionRecovery = true }
                    } else {
                        self.capture.invalidate()
                        self.audioRequest = UUID()
                        self.isConfiguringAudio = false
                        self.capture.requestStop()
                        self.problem = .noPreview
                        // New observers allow the matching interruption-ended event
                        // while callbacks from the old generation are rejected.
                        self.installSessionObservers(generation: self.capture.generation)
                        self.sessionQueue.async { [weak self] in
                            self?.setAcceptingFrames(false)
                            self?.requestRecordingStop()
                        }
                    }
                }
            }
            sessionObservers.tokens.append(observer)
        }
    }

    private func rebuild(generation: UUID, zoom: CGFloat, torch: TorchLevel) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard wantsRunning, sessionGeneration == generation else { return }
        setAcceptingFrames(false)
        if session.isRunning { session.stopRunning() }
        tearDownConfiguration()
        startIfNeeded(zoom: zoom, torch: torch)
    }

    @MainActor private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish capture") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.media.markInFlightUncertain()
                self.endBackgroundTask()
            }
        }
        Task { @MainActor [weak self] in
            while let self, self.backgroundTask != .invalid {
                if !self.isRecording && !self.isCapturingPhoto && !self.media.records.contains(where: { $0.saveState == .saving }) {
                    self.endBackgroundTask()
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    @MainActor private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        let task = backgroundTask
        backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }

    @MainActor func updatePreviewSize(_ size: CGSize) {
        guard abs(size.width - previewSize.width) > 0.5 || abs(size.height - previewSize.height) > 0.5 else {
            return
        }
        previewSize = size
    }

    @MainActor func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        PortraitRotation.apply(to: layer.connection)
    }

    @MainActor func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            pinchBaseline = zoomFactor
        case .changed:
            setZoom(pinchBaseline * recognizer.scale, animated: false)
        default:
            break
        }
    }

    @MainActor func focus(at viewPoint: CGPoint) {
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

    @MainActor func resetZoom() {
        let target = ZoomScale.clamp(1, min: minZoom, max: maxZoom)
        setZoom(target, animated: true)
    }

    @MainActor func setZoom(_ requested: CGFloat, animated: Bool) {
        let clamped = ZoomScale.clamp(requested, min: minZoom, max: maxZoom)
        zoomFactor = clamped
        sessionQueue.async { [weak self] in
            self?.applyZoom(clamped, animated: animated)
        }
    }

    @MainActor func cycleTorch() {
        guard torchAvailable else {
            alert = AppAlert(title: L10n.torchUnavailableTitle, message: L10n.torchUnavailableBody)
            return
        }
        let next = torchLevel.next
        sessionQueue.async { [weak self] in
            self?.applyTorch(next)
        }
    }

    @MainActor func setAudioEnabled(_ enabled: Bool) {
        guard interactive, !isRecording, !isCapturingPhoto, !isConfiguringAudio else { return }
        isConfiguringAudio = true
        let request = UUID()
        audioRequest = request
        let generation = capture.generation
        let zoom = zoomFactor
        let torch = torchLevel
        Task { @MainActor in
            let granted = enabled ? await self.awaitMicrophoneAccess() : true
            // The async permission callback may belong to a previous session.
            guard self.audioRequest == request, self.capture.generation == generation,
                  self.foreground else { return }
            guard granted else {
                self.isConfiguringAudio = false
                self.audioEnabled = false
                self.alert = AppAlert(title: L10n.audioDeniedTitle, message: L10n.audioDeniedBody)
                return
            }
            self.sessionQueue.async { [weak self] in
                guard let self, self.sessionGeneration == generation else { return }
                self.audioPreference.select(enabled)
                let added: Bool
                if enabled {
                    added = self.addAudioInput(zoom: zoom, torch: torch)
                } else {
                    self.removeAudioInput(zoom: zoom, torch: torch)
                    added = false
                }
                Task { @MainActor in
                    guard self.audioRequest == request, self.capture.generation == generation else { return }
                    self.isConfiguringAudio = false
                    self.audioEnabled = added
                    if enabled && !added {
                        self.alert = AppAlert(title: L10n.audioDeniedTitle, message: L10n.audioDeniedBody)
                    }
                }
            }
        }
    }

    @MainActor private func awaitMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
        }
    }

    @MainActor func toggleRecording() {
        if isRecording {
            capture.requestStop()
            sessionQueue.async { [weak self] in self?.requestRecordingStop() }
            return
        }
        guard interactive, canRecord, !isConfiguringAudio, frozenPhoto == nil,
              capture.beginRecording() else { return }
        do {
            let record = try media.reserve(.video)
            activeRecording = record
            let url = media.url(for: record)
            let generation = capture.generation
            sessionQueue.async { [weak self] in self?.beginRecording(to: url, generation: generation) }
        } catch {
            capture.finish()
            alert = AppAlert(title: L10n.recordFailedTitle, message: L10n.recordFailedBody)
        }
    }

    @MainActor func capturePhoto() {
        guard interactive, !isConfiguringAudio, frozenPhoto == nil, capture.beginPhoto() else { return }
        let record: MediaRecord
        do { record = try media.reserve(.photo) }
        catch {
            capture.finish()
            alert = AppAlert(title: L10n.recordFailedTitle, message: L10n.recordFailedBody)
            return
        }
        let url = media.url(for: record)
        let size = previewSize
        let generation = capture.generation
        frameQueue.async { [weak self] in
            guard let self else { return }
            self.bufferLock.lock()
            let buffer = self.frameGeneration == generation && self.acceptingFrames ? self.latestPixelBuffer : nil
            self.bufferLock.unlock()
            let rendered = buffer.flatMap { self.render(buffer: $0, previewSize: size, to: url) }
            Task { @MainActor in
                self.capture.finish()
                self.media.finish(record.id, complete: rendered != nil)
                guard let rendered else {
                    self.alert = AppAlert(title: L10n.captureNotReadyTitle, message: L10n.captureNotReadyBody)
                    return
                }
                // Keep the media even if the app was backgrounded while rendering.
                if self.capture.generation == generation {
                    self.frozenPhoto = FrozenPhoto(id: record.id, image: rendered, fileURL: url)
                }
                await self.media.save(record.id)
            }
        }
    }

    @MainActor func dismissFreeze() { frozenPhoto = nil }
    @MainActor func dismissClip() { recordedClip = nil }

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
        // Drain old delegate callbacks before arming this generation.
        let frameToken = sessionGeneration
        frameQueue.sync {
            self.bufferLock.lock()
            self.frameGeneration = frameToken
            self.didReportFirstFrame = false
            self.latestPixelBuffer = nil
            self.acceptingFrames = true
            self.bufferLock.unlock()
        }
        if !session.isRunning {
            session.startRunning()
        }
        if !didApplyDataRotation || !didConfigureCodec {
            configureConnections()
        }
        applyZoom(zoom, animated: false)
        applyTorch(torch)
        let running = session.isRunning
        let generation = sessionGeneration
        Task { @MainActor in
            guard self.capture.generation == generation else { return }
            if !running, self.problem == nil {
                self.problem = .noPreview
            }
        }
    }

    private func stopIfNeeded() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        setAcceptingFrames(false)
        clearLatestBuffer()
        if recordingURL != nil {
            requestRecordingStop()
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
        observeTorch(on: device)

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
        let requestedAudio = audioPreference.requested
        let actualAudio = audioPreference.restore {
            addAudioInput(zoom: device.videoZoomFactor, torch: .off)
        }
        let generation = sessionGeneration

        let closeUp = deviceSupportsCloseFocus(device)
        let hasTorch = device.hasTorch && device.isTorchAvailable
        logger.info("Camera \(device.deviceType.rawValue, privacy: .public) closeUp=\(closeUp ? "yes" : "no", privacy: .public)")
        Task { @MainActor in
            guard self.capture.generation == generation else { return }
            self.audioEnabled = actualAudio
            self.isConfiguringAudio = false
            if requestedAudio && !actualAudio {
                self.alert = AppAlert(title: L10n.audioDeniedTitle, message: L10n.audioDeniedBody)
            }
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
        torchObservations.forEach { $0.invalidate() }
        torchObservations = []
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
                device.isGeometricDistortionCorrectionEnabled = true
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
            let generation = sessionGeneration
            Task { @MainActor in
                guard self.capture.generation == generation else { return }
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
                guard let self, self.videoDevice === device, Date() > self.ignoreSubjectFocusUntil else { return }
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
            self?.sessionQueue.async { [weak self] in
                guard let self, self.videoDevice === device else { return }
                let factor = device.videoZoomFactor
                let generation = self.sessionGeneration
                Task { @MainActor in
                    guard self.capture.generation == generation else { return }
                    if self.zoomFactor != factor { self.zoomFactor = factor }
                }
            }
        }
    }

    private func observeTorch(on device: AVCaptureDevice) {
        torchObservations = [
            device.observe(\.isTorchAvailable, options: [.new]) { [weak self] device, _ in
                self?.queueTorchState(for: device)
            },
            device.observe(\.isTorchActive, options: [.new]) { [weak self] device, _ in
                self?.queueTorchState(for: device)
            }
        ]
    }

    private func queueTorchState(for device: AVCaptureDevice) {
        sessionQueue.async { [weak self] in
            guard let self, self.videoDevice === device else { return }
            self.publishTorchState()
        }
    }

    private func publishTorchState() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        let available = videoDevice?.isTorchAvailable == true
        let level = videoDevice?.isTorchActive == true ? requestedTorch : .off
        let generation = sessionGeneration
        Task { @MainActor in
            guard self.capture.generation == generation else { return }
            if self.torchAvailable != available { self.torchAvailable = available }
            if self.torchLevel != level { self.torchLevel = level }
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
        requestedTorch = level
        defer { publishTorchState() }
        guard let device = videoDevice, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if level == .off {
                device.torchMode = .off
            } else if device.isTorchAvailable {
                try device.setTorchModeOn(level: min(level.brightness, AVCaptureDevice.maxAvailableTorchLevel))
            } else {
                requestedTorch = .off
                publishTorchFailure()
            }
        } catch {
            requestedTorch = .off
            logger.error("Torch failed: \(error.localizedDescription, privacy: .public)")
            publishTorchFailure()
        }
    }

    private func publishTorchFailure() {
        let generation = sessionGeneration
        Task { @MainActor in
            guard self.capture.generation == generation else { return }
            self.alert = AppAlert(title: L10n.torchUnavailableTitle, message: L10n.torchUnavailableBody)
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

    private func beginRecording(to url: URL, generation: UUID) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard wantsRunning, sessionGeneration == generation, recordingURL == nil,
              session.isRunning, session.outputs.contains(where: { $0 === movieOutput }) else {
            Task { @MainActor in
                guard let record = self.activeRecording, self.media.url(for: record) == url else { return }
                self.media.finish(record.id, complete: false)
                self.activeRecording = nil
                self.capture.finish()
                self.alert = AppAlert(title: L10n.recordFailedTitle, message: L10n.recordFailedBody)
            }
            return
        }
        recordingStopRequested = false
        recordingURL = url
        PortraitRotation.apply(to: movieOutput.connection(with: .video))
        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    private func requestRecordingStop() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard recordingURL != nil else { return }
        recordingStopRequested = true
        if movieOutput.isRecording { movieOutput.stopRecording() }
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
        let generation = sessionGeneration
        Task { @MainActor in
            guard self.capture.generation == generation else { return }
            self.problem = problem
        }
    }

    @MainActor private func scheduleReadyTimeout() {
        readyTimeoutToken += 1
        let token = readyTimeoutToken
        let generation = capture.generation
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(MagnifierConfig.readyTimeout * 1_000_000_000.0))
            guard self.capture.generation == generation, self.foreground, self.readyTimeoutToken == token, !self.isReady, self.authorization == .authorized else { return }
            if self.problem == nil {
                self.problem = .noPreview
            }
        }
    }

    @MainActor private func showFocusIndicator(at point: CGPoint) {
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

    private func render(buffer: CVPixelBuffer, previewSize: CGSize, to url: URL) -> UIImage? {
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
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Could not write JPEG: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return uiImage
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
        let generation = frameGeneration
        let reportReady = accept && !didReportFirstFrame
        if accept { latestPixelBuffer = buffer }
        if reportReady { didReportFirstFrame = true }
        bufferLock.unlock()
        guard reportReady else { return }
        Task { @MainActor in
            if self.capture.firstFrame(for: generation) {
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
        sessionQueue.async { [weak self] in
            guard let self, self.recordingURL == fileURL else { return }
            if self.recordingStopRequested || !self.wantsRunning { self.movieOutput.stopRecording() }
            Task { @MainActor in
                guard let record = self.activeRecording, self.media.url(for: record) == fileURL else { return }
                self.recordingStartedAt = Date()
                if self.capture.recordingDidStart() {
                    self.sessionQueue.async { [weak self] in self?.requestRecordingStop() }
                }
            }
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let nsError = error as NSError?
        let usable = error == nil || nsError?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
        sessionQueue.async { [weak self] in
            guard let self, self.recordingURL == outputFileURL else { return }
            self.recordingURL = nil
            self.recordingStopRequested = false
            if !self.wantsRunning, self.session.isRunning {
                self.setAcceptingFrames(false)
                self.session.stopRunning()
            }
            if let (generation, zoom, torch) = self.pendingRebuild {
                self.pendingRebuild = nil
                self.rebuild(generation: generation, zoom: zoom, torch: torch)
            }
            Task {
                let asset = AVURLAsset(url: outputFileURL)
                let duration = (try? await asset.load(.duration))?.seconds ?? 0
                let playable = (try? await asset.load(.isPlayable)) ?? false
                let bytes = (try? outputFileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                let valid = usable && playable && duration.isFinite && duration > 0 && bytes > 0
                let preview = valid ? self.thumbnail(for: outputFileURL) : nil
                await self.finishRecording(at: outputFileURL, valid: valid, duration: duration, preview: preview)
            }
        }
    }

    @MainActor private func finishRecording(at url: URL, valid: Bool, duration: TimeInterval, preview: UIImage?) async {
        guard let record = activeRecording, media.url(for: record) == url else { return }
        activeRecording = nil
        capture.finish()
        recordingStartedAt = nil
        media.finish(record.id, complete: valid, duration: valid ? duration : nil)
        guard valid else {
            alert = AppAlert(title: L10n.recordFailedTitle, message: L10n.recordFailedBody)
            return // Retain questionable output for recovery or explicit discard.
        }
        recordedClip = RecordedClip(id: record.id, url: url, thumbnail: preview, duration: duration)
        await media.save(record.id)
    }
}

/// Removing block observers also releases NotificationCenter's retained closures.
private final class NotificationBag {
    var tokens: [NSObjectProtocol] = []
    func clear() {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
        tokens = []
    }
    deinit { clear() }
}
