import AppKit
import SwiftUI

#if !SNAPSHOT
@main
#endif
struct HallucinationEngineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var engine = Engine()

    var body: some Scene {
        WindowGroup("Hallucination Engine") {
            ContentView()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)

        Window("Prompt Preview", id: "prompt-preview") {
            PromptPreviewWindow()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        true
    }
}
