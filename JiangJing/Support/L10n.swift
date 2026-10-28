import Foundation

/// Keys live in `Localizable.strings`. Chinese is the development language.
enum L10n {
    static var permTitle: String { String(localized: "perm.title") }
    static var permBody: String { String(localized: "perm.body") }
    static var permAllow: String { String(localized: "perm.allow") }
    static var permDeniedTitle: String { String(localized: "perm.denied.title") }
    static var permDeniedBody: String { String(localized: "perm.denied.body") }
    static var permSettings: String { String(localized: "perm.settings") }

    static var cameraStarting: String { String(localized: "camera.starting") }
    static var cameraNoneTitle: String { String(localized: "camera.none.title") }
    static var cameraNoneBody: String { String(localized: "camera.none.body") }
    static var cameraStalledTitle: String { String(localized: "camera.stalled.title") }
    static var cameraStalledBody: String { String(localized: "camera.stalled.body") }
    static var cameraRetry: String { String(localized: "camera.retry") }

    static var hintGestures: String { String(localized: "hint.gestures") }
    static var badgeCloseUp: String { String(localized: "badge.closeup") }

    static var torchOff: String { String(localized: "torch.off") }
    static var torchLow: String { String(localized: "torch.low") }
    static var torchMedium: String { String(localized: "torch.medium") }
    static var torchHigh: String { String(localized: "torch.high") }
    static var torchUnavailableTitle: String { String(localized: "torch.unavailable.title") }
    static var torchUnavailableBody: String { String(localized: "torch.unavailable.body") }

    static var actionPhoto: String { String(localized: "action.photo") }
    static var actionRecord: String { String(localized: "action.record") }
    static var actionStop: String { String(localized: "action.stop") }
    static var actionAudio: String { String(localized: "action.audio") }
    static var actionShare: String { String(localized: "action.share") }
    static var actionContinue: String { String(localized: "action.continue") }
    static var actionClose: String { String(localized: "action.close") }
    static var actionSettings: String { String(localized: "action.settings") }

    static var captureSaving: String { String(localized: "capture.saving") }
    static var captureSaved: String { String(localized: "capture.saved") }
    static var captureSaveDenied: String { String(localized: "capture.saveDenied") }
    static var captureSaveFailed: String { String(localized: "capture.saveFailed") }
    static var captureNotReadyTitle: String { String(localized: "capture.notReady.title") }
    static var captureNotReadyBody: String { String(localized: "capture.notReady.body") }

    static var recordFailedTitle: String { String(localized: "record.failed.title") }
    static var recordFailedBody: String { String(localized: "record.failed.body") }
    static var recordShareHint: String { String(localized: "record.shareHint") }

    static var audioDeniedTitle: String { String(localized: "audio.denied.title") }
    static var audioDeniedBody: String { String(localized: "audio.denied.body") }

    static var freezeHint: String { String(localized: "freeze.hint") }

    static var a11yZoom: String { String(localized: "a11y.zoom") }
    static var a11yPhoto: String { String(localized: "a11y.photo") }
    static var a11yRecord: String { String(localized: "a11y.record") }
    static var a11yStop: String { String(localized: "a11y.stop") }
    static var a11yTorch: String { String(localized: "a11y.torch") }
    static var a11yAudioOn: String { String(localized: "a11y.audio.on") }
    static var a11yAudioOff: String { String(localized: "a11y.audio.off") }
    static var a11yShare: String { String(localized: "a11y.share") }
    static var a11yContinue: String { String(localized: "a11y.continue") }
    static var a11yPresets: String { String(localized: "a11y.presets") }
}
