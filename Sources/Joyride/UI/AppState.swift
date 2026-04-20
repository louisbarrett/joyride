import Foundation
import Combine
import SwiftUI

/// Top-level observable state shared across the SwiftUI view hierarchy.
final class AppState: ObservableObject {
    let joyConManager: JoyConManager
    let profileStore: ProfileStore
    let engine: MappingEngine

    @Published var isEnabled: Bool = true {
        didSet { engine.setEnabled(isEnabled) }
    }

    @Published var hasAccessibilityPermission: Bool = AccessibilityPermission.isGranted()
    @Published var inputMonitoringStatus: InputMonitoringPermission.Status = InputMonitoringPermission.status()

    private var permissionPollTimer: Timer?

    private var servicesStarted = false

    init() {
        let jcm = JoyConManager()
        let store = ProfileStore()
        self.joyConManager = jcm
        self.profileStore = store
        self.engine = MappingEngine(profileStore: store, joyConManager: jcm)

        // Start services immediately so we don't depend on SwiftUI view-lifecycle timing
        // (which used to leave services un-started until the user first opened the popover).
        startServices()
    }

    func startServices() {
        guard !servicesStarted else { return }
        servicesStarted = true

        // Input Monitoring must be granted *before* IOHIDManager will deliver reports from
        // paired Nintendo controllers on macOS 10.15+. We request it up-front so the
        // system prompt shows the moment the user launches.
        if InputMonitoringPermission.status() != .granted {
            InputMonitoringPermission.request()
        }

        joyConManager.start()
        engine.start()
        startPermissionPolling()
    }

    /// Called by the UI when the user grants Input Monitoring so we can pick up devices
    /// that were invisible at launch without the user having to quit and relaunch.
    func rescanControllers() {
        joyConManager.restart()
    }

    func stopServices() {
        engine.stop()
        joyConManager.stop()
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    private func startPermissionPolling() {
        permissionPollTimer?.invalidate()
        // Poll once a second so the UI re-enables actions as soon as the user grants
        // Accessibility or Input Monitoring in System Settings.
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let granted = AccessibilityPermission.isGranted()
            let imStatus = InputMonitoringPermission.status()
            DispatchQueue.main.async {
                if granted != self.hasAccessibilityPermission {
                    self.hasAccessibilityPermission = granted
                }
                if imStatus != self.inputMonitoringStatus {
                    let wasBlocked = self.inputMonitoringStatus != .granted
                    self.inputMonitoringStatus = imStatus
                    // If we were blocked and just became granted, rescan controllers so
                    // devices show up without requiring a restart.
                    if wasBlocked && imStatus == .granted {
                        self.rescanControllers()
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer
    }
}
