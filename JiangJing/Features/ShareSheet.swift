import UIKit

/// Presents the system share sheet from the active window. The completion
/// releases the file lease after sharing or cancellation.
@MainActor
enum ShareCenter {
    static func present(items: [Any], completion: @escaping () -> Void) -> Bool {
        guard !items.isEmpty, let presenter = topViewController() else { return false }
        guard presenter.presentedViewController == nil else { return false }
        guard !presenter.isBeingDismissed, !presenter.isBeingPresented else { return false }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in completion() }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            let bounds = presenter.view.bounds
            popover.sourceRect = CGRect(x: bounds.midX, y: bounds.maxY - 48, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        presenter.present(controller, animated: true)
        return true
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
