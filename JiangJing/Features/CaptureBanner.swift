import SwiftUI
import UIKit

struct ClipBanner: View {
    let clip: RecordedClip
    var onShare: () -> Void
    var onClose: () -> Void
    var onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                thumbnail
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusText)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                    Text(L10n.recordShareHint)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                    Text(ClockFormat.string(from: clip.duration))
                        .font(.system(.subheadline, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                }
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.16), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.actionClose)
            }
            Button(action: onShare) {
                Label(L10n.actionShare, systemImage: "square.and.arrow.up")
            }
            .buttonStyle(CraftButtonStyle())
            .accessibilityLabel(L10n.a11yShare)
            if clip.saveState == .denied {
                Button(L10n.actionSettings, action: onSettings)
                    .buttonStyle(CraftButtonStyle(prominent: false))
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var statusText: String {
        switch clip.saveState {
        case .saving: return L10n.captureSaving
        case .saved: return L10n.captureSaved
        case .denied: return L10n.captureSaveDenied
        case .failed: return L10n.captureSaveFailed
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        Group {
            if let image = clip.thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "video.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white.opacity(0.12))
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct FreezeOverlay: View {
    let photo: FrozenPhoto
    var onShare: () -> Void
    var onContinue: () -> Void
    var onSettings: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.freezeHint)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                Text(statusText)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                Button(action: onShare) {
                    Label(L10n.actionShare, systemImage: "square.and.arrow.up")
                }
                .buttonStyle(CraftButtonStyle())
                .accessibilityLabel(L10n.a11yShare)
                if photo.saveState == .denied {
                    Button(L10n.actionSettings, action: onSettings)
                        .buttonStyle(CraftButtonStyle(prominent: false))
                }
                Button(L10n.actionContinue, action: onContinue)
                    .buttonStyle(CraftButtonStyle(prominent: false))
                    .accessibilityLabel(L10n.a11yContinue)
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private var statusText: String {
        switch photo.saveState {
        case .saving: return L10n.captureSaving
        case .saved: return L10n.captureSaved
        case .denied: return L10n.captureSaveDenied
        case .failed: return L10n.captureSaveFailed
        }
    }
}
