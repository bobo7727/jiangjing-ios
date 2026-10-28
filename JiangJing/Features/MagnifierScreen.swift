import SwiftUI
import UIKit

struct MagnifierScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @StateObject private var model = CameraController()
    @State private var showHint = true

    var body: some View {
        ZStack {
            CraftColor.ink
            if model.authorization != .authorized {
                PermissionView(
                    denied: model.authorization != .notDetermined,
                    allow: { model.requestCameraAccess() },
                    openSettings: openSettings
                )
            } else if let problem = model.problem {
                ProblemView(problem: problem, retry: { model.restart() })
            } else {
                cameraStage
            }
        }
        .alert(
            model.alert?.title ?? "",
            isPresented: alertPresented,
            actions: {
                Button(L10n.actionClose, role: .cancel) {}
            },
            message: {
                Text(model.alert?.message ?? "")
            }
        )
        .onAppear {
            model.onForeground()
            scheduleHintDismissal()
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                model.onForeground()
            case .background:
                model.onBackground()
            default:
                break
            }
        }
    }

    private var alertPresented: Binding<Bool> {
        Binding(
            get: { model.alert != nil },
            set: { presented in
                if !presented { model.alert = nil }
            }
        )
    }

    private var cameraStage: some View {
        ZStack {
            CameraPreviewView(
                session: model.session,
                focusPoint: model.focusPoint,
                onPinch: { recognizer in
                    showHint = false
                    model.handlePinch(recognizer)
                },
                onTap: { point in
                    showHint = false
                    model.focus(at: point)
                },
                onDoubleTap: {
                    showHint = false
                    Haptics.tap()
                    model.resetZoom()
                },
                onLayout: { model.updatePreviewSize($0) },
                onLayerReady: { model.attachPreviewLayer($0) }
            )
            .ignoresSafeArea()

            if let photo = model.frozenPhoto {
                Image(uiImage: photo.image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .ignoresSafeArea()
                    .accessibilityLabel(L10n.freezeHint)
            }

            LinearGradient(
                colors: [.black.opacity(0.55), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 180)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .allowsHitTesting(false)

            LinearGradient(
                colors: [.clear, .black.opacity(0.78)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 340)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea()
            .allowsHitTesting(false)

            if model.isRecording {
                Rectangle()
                    .strokeBorder(Color.red.opacity(0.9), lineWidth: 4)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            VStack(spacing: 12) {
                topBar
                if showHint, model.frozenPhoto == nil, !model.isRecording {
                    Text(L10n.hintGestures)
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.45), in: Capsule())
                        .transition(.opacity)
                }
                Spacer()
                if model.frozenPhoto == nil, let clip = model.recordedClip {
                    ClipBanner(
                        clip: clip,
                        onShare: { ShareCenter.present(items: [clip.url]) },
                        onClose: { model.dismissClip() },
                        onSettings: openSettings
                    )
                }
                if let photo = model.frozenPhoto {
                    FreezeOverlay(
                        photo: photo,
                        onShare: { ShareCenter.present(items: [photo.fileURL]) },
                        onContinue: { model.dismissFreeze() },
                        onSettings: openSettings
                    )
                } else {
                    ControlBar(model: model)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 8)

            if !model.isReady {
                startingOverlay
                    .ignoresSafeArea()
            }
        }
    }

    private var topBar: some View {
        ZStack {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(ZoomScale.format(model.zoomFactor))
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .accessibilityLabel(L10n.a11yZoom)
                        .accessibilityValue(ZoomScale.format(model.zoomFactor))
                    if model.usesCloseUpCamera {
                        Text(L10n.badgeCloseUp)
                            .font(.system(.caption, design: .rounded).weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(CraftColor.amber, in: Capsule())
                    }
                }
                Spacer()
                audioButton
            }
            if model.isRecording, let started = model.recordingStartedAt {
                RecordingClock(startedAt: started)
            }
        }
    }

    private var audioButton: some View {
        Button {
            Haptics.tap()
            model.setAudioEnabled(!model.audioEnabled)
        } label: {
            ZStack {
                Circle()
                    .fill(model.audioEnabled ? CraftColor.amber : Color.white.opacity(0.16))
                if model.isConfiguringAudio {
                    ProgressView()
                        .tint(model.audioEnabled ? .black : .white)
                } else {
                    Image(systemName: model.audioEnabled ? "mic.fill" : "mic.slash.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(model.audioEnabled ? Color.black : Color.white)
                }
            }
            .frame(width: 56, height: 56)
        }
        .buttonStyle(.plain)
        .disabled(model.isRecording || model.isConfiguringAudio)
        .accessibilityLabel(model.audioEnabled ? L10n.a11yAudioOn : L10n.a11yAudioOff)
        .accessibilityHint(L10n.actionAudio)
    }

    private var startingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 16) {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.2)
                Text(L10n.cameraStarting)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundStyle(.white)
            }
        }
        .allowsHitTesting(true)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    private func scheduleHintDismissal() {
        DispatchQueue.main.asyncAfter(deadline: .now() + MagnifierConfig.hintVisibleDuration) {
            withAnimation(.easeOut(duration: 0.3)) {
                showHint = false
            }
        }
    }
}

private struct RecordingClock: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 0.5)) { context in
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                Text(ClockFormat.string(from: context.date.timeIntervalSince(startedAt)))
                    .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.55), in: Capsule())
        }
        .accessibilityLabel(L10n.actionRecord)
    }
}

private struct PermissionView: View {
    let denied: Bool
    let allow: () -> Void
    let openSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 72, weight: .regular))
                    .foregroundStyle(CraftColor.amber)
                    .padding(.top, 48)
                Text(denied ? L10n.permDeniedTitle : L10n.permTitle)
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(denied ? L10n.permDeniedBody : L10n.permBody)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if denied {
                    Button(L10n.permSettings, action: openSettings)
                        .buttonStyle(CraftButtonStyle())
                } else {
                    Button(L10n.permAllow, action: allow)
                        .buttonStyle(CraftButtonStyle())
                }
            }
            .padding(28)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct ProblemView: View {
    let problem: CameraProblem
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.fill")
                .font(.system(size: 56))
                .foregroundStyle(CraftColor.amber)
            Text(problem == .noCamera ? L10n.cameraNoneTitle : L10n.cameraStalledTitle)
                .font(.system(.title, design: .rounded).weight(.semibold))
                .multilineTextAlignment(.center)
            Text(problem == .noCamera ? L10n.cameraNoneBody : L10n.cameraStalledBody)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if problem == .noPreview {
                Button(L10n.cameraRetry, action: retry)
                    .buttonStyle(CraftButtonStyle())
            }
        }
        .padding(28)
        .frame(maxWidth: 520)
    }
}
