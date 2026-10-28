import UIKit

/// Presents the system share sheet from the active window so WeChat and other
/// apps receive the file. A SwiftUI `.sheet` wrapping this controller nests two
/// presentations and drops the file on some iOS versions.
enum ShareCenter {
    static func present(items: [Any]) {
        guard !items.isEmpty, let presenter = topViewController() else { return }
        guard presenter.presentedViewController == nil else { return }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            let bounds = presenter.view.bounds
            popover.sourceRect = CGRect(x: bounds.midX, y: bounds.maxY - 48, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        presenter.present(controller, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let root = scene?.keyWindow?.rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}
