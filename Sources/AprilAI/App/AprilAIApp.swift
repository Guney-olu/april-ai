import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct AprilAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("April AI") {
            MainView()
                .environmentObject(state)
                .frame(minWidth: 980, minHeight: 680)
        }

        MenuBarExtra("April AI", systemImage: "brain.head.profile") {
            MenuBarView()
                .environmentObject(state)
        }
        .menuBarExtraStyle(.window)
    }
}
