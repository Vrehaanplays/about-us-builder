import SwiftUI
import UIKit

@main
struct PersonalAIApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ThemedRoot { RootView() }
                .environment(model)
                .onChange(of: phase) { _, new in model.scenePhaseChanged(new) }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in model.memoryWarning() }
        }
    }
}
