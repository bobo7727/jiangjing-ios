import SwiftUI

struct ControlBar: View {
    @ObservedObject var model: CameraController
    @State private var sliderValue = 0.0
    @State private var isDraggingSlider = false

    var body: some View {
        VStack(spacing: 14) {
            presets
            zoomSlider
            HStack(alignment: .center) {
                torchButton
                Spacer(minLength: 12)
                shutterButton
                Spacer(minLength: 12)
                recordButton
            }
        }
    }

    private var presets: some View {
        let factors = ZoomScale.presets(min: model.minZoom, max: model.maxZoom)
        return ViewThatFits(in: .horizontal) {
            presetRow(factors)
            ScrollView(.horizontal, showsIndicators: false) {
                presetRow(factors)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.a11yPresets)
    }

    private func presetRow(_ factors: [CGFloat]) -> some View {
        HStack(spacing: 8) {
            ForEach(factors, id: \.self) { factor in
                let selected = ZoomScale.matches(model.zoomFactor, preset: factor)
                Button {
                    Haptics.tap()
                    model.setZoom(factor, animated: true)
                } label: {
                    Text(ZoomScale.format(factor))
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(selected ? Color.black : Color.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(selected ? CraftColor.amber : Color.white.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var zoomSlider: some View {
        HStack(spacing: 10) {
            Text(ZoomScale.format(model.minZoom))
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 40, alignment: .leading)
            Slider(value: $sliderValue, in: 0...1, onEditingChanged: { editing in
                isDraggingSlider = editing
                if !editing {
                    syncSlider()
                }
            })
            .tint(CraftColor.amber)
            .disabled(model.maxZoom - model.minZoom < 0.05)
            .accessibilityLabel(L10n.a11yZoom)
            .accessibilityValue(ZoomScale.format(model.zoomFactor))
            Text(ZoomScale.format(model.maxZoom))
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 40, alignment: .trailing)
        }
        .onAppear(perform: syncSlider)
        .onChange(of: model.zoomFactor) { _ in
            guard !isDraggingSlider else { return }
            syncSlider()
        }
        .onChange(of: model.minZoom) { _ in syncSlider() }
        .onChange(of: model.maxZoom) { _ in syncSlider() }
        .onChange(of: sliderValue) { newValue in
            guard isDraggingSlider else { return }
            let factor = ZoomScale.factor(forSlider: newValue, min: model.minZoom, max: model.maxZoom)
            model.setZoom(factor, animated: false)
        }
    }

    private var torchButton: some View {
        ToolButton(
            systemName: model.torchLevel.symbolName,
            title: model.torchLevel.title,
            active: model.torchLevel != .off,
            useDarkIcon: model.torchLevel != .off,
            enabled: model.torchAvailable
        ) {
            Haptics.tap()
            model.cycleTorch()
        }
        .accessibilityLabel(L10n.a11yTorch)
        .accessibilityValue(model.torchLevel.title)
    }

    private var shutterButton: some View {
        Button {
            Haptics.shutter()
            model.capturePhoto()
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .strokeBorder(.white, lineWidth: 4)
                        .frame(width: 78, height: 78)
                    Circle()
                        .fill(.white)
                        .frame(width: 62, height: 62)
                        .padding(8)
                }
                .opacity(model.isCapturingPhoto ? 0.55 : 1)
                Text(L10n.actionPhoto)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .disabled(!model.isReady || model.isRecording || model.isCapturingPhoto)
        .accessibilityLabel(L10n.a11yPhoto)
    }

    private var recordButton: some View {
        ToolButton(
            systemName: model.isRecording ? "stop.fill" : "circle.fill",
            title: model.isRecording ? L10n.actionStop : L10n.actionRecord,
            active: model.isRecording,
            activeColor: .red,
            symbolColor: model.isRecording ? .white : .red
        ) {
            Haptics.tap()
            model.toggleRecording()
        }
        .disabled(!model.canRecord || !model.isReady || model.isConfiguringAudio)
        .accessibilityLabel(model.isRecording ? L10n.a11yStop : L10n.a11yRecord)
    }

    private func syncSlider() {
        sliderValue = ZoomScale.sliderPosition(
            for: model.zoomFactor,
            min: model.minZoom,
            max: model.maxZoom
        )
    }
}

struct ToolButton: View {
    let systemName: String
    let title: String
    var active = false
    var activeColor = CraftColor.amber
    var symbolColor = Color.white
    var useDarkIcon = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(active ? activeColor : Color.white.opacity(0.16))
                    Image(systemName: systemName)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(useDarkIcon ? Color.black : symbolColor)
                }
                .frame(width: 68, height: 68)
                Text(title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(minWidth: 76)
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

struct CraftButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.title3, design: .rounded).weight(.semibold))
            .foregroundStyle(prominent ? Color.black : Color.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
            .padding(.horizontal, 16)
            .background(
                prominent ? CraftColor.amber : Color.white.opacity(0.16),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
