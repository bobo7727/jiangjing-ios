import SwiftUI
import UIKit

@main
struct JiangJingApp: App {
    var body: some Scene {
        WindowGroup {
            MagnifierScreen()
                .preferredColorScheme(.dark)
                .tint(CraftColor.amber)
                .modifier(KeepScreenAwake())
        }
    }
}

/// The phone is a tool on the bench. While JiangJing is open, the screen stays lit.
private struct KeepScreenAwake: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true
            }
            .onChange(of: scenePhase) { phase in
                UIApplication.shared.isIdleTimerDisabled = phase != .background
            }
    }
}
