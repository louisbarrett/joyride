import AppKit

/// Handles application lifecycle concerns that SwiftUI's `App` protocol doesn't expose cleanly:
/// accessory activation policy (menu-bar-only, no Dock icon) and graceful shutdown.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // We're a menu-bar utility — no Dock tile, no app menu.
        NSApp.setActivationPolicy(.accessory)
        appState?.startServices()

        // Prompt for Accessibility on first launch so the user sees the OS dialog immediately.
        if !AccessibilityPermission.isGranted() {
            AccessibilityPermission.requestAndOpenSettingsIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Flush any pending debounced profile and calibration writes before we tear
        // down services — otherwise an edit made in the last ~300 ms before quit
        // would be lost.
        appState?.profileStore.flushPendingWrites()
        appState?.joyConManager.calibrationStore.flushPendingWrites()
        appState?.stopServices()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Stay alive in the menu bar even when the mapping editor is closed.
        return false
    }
}
