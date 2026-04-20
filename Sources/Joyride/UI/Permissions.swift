import Foundation
import AppKit
import ApplicationServices
import IOKit
import IOKit.hid

/// Wrapper around the macOS Accessibility permission check/prompt. Required for
/// `CGEvent` injection to actually reach other apps.
enum AccessibilityPermission {
    /// Returns true if our process currently has Accessibility permission.
    static func isGranted() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Prompt the user. The system displays its own sheet the first time; subsequent calls
    /// do nothing until the setting is toggled, so we open System Settings manually too.
    static func requestAndOpenSettingsIfNeeded() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        if !trusted {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

/// Bluetooth permission is implicitly granted for plain HID / IOKit usage (we don't use
/// CoreBluetooth), but we still surface a helper to open Settings in case the user needs
/// to pair a controller.
enum BluetoothSettings {
    static func openPairingPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.Bluetooth") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Helpers for working with this app's bundle on disk. Useful when the user needs to
/// drag the app into a privacy pane manually (common workaround for ad-hoc-signed builds
/// that TCC fails to register automatically).
enum AppBundle {
    static var bundleURL: URL {
        Bundle.main.bundleURL
    }

    static var bundlePath: String {
        bundleURL.path
    }

    static func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
    }

    static func copyPathToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bundlePath, forType: .string)
    }

    /// Version string assembled from the Info.plist `CFBundleShortVersionString` plus a
    /// build timestamp baked in at compile time. Surfaced in the popover footer so the
    /// user can verify at a glance which binary they're running.
    static var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "v\(short) (\(build))"
    }

    /// Compile-time timestamp: this string is stamped in at build time by the build script
    /// via the `JOYRIDE_BUILD_STAMP` environment variable. Falls back to the bundle mtime
    /// so even `swift run` gives us a useful value.
    static var buildStamp: String {
        if let env = ProcessInfo.processInfo.environment["JOYRIDE_BUILD_STAMP"], !env.isEmpty {
            return env
        }
        let path = Bundle.main.executableURL?.path ?? bundlePath
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let date = attrs[.modificationDate] as? Date {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return f.string(from: date)
        }
        return "unknown"
    }
}

/// On macOS 10.15+ reading HID input reports from paired peripherals (keyboards,
/// controllers, etc.) requires the process to be granted *Input Monitoring* access
/// in Privacy & Security. This is **separate** from Accessibility: Accessibility
/// governs synthesizing events; Input Monitoring governs receiving them.
///
/// Without it, IOHIDManager will happily enumerate the Joy-Con but never deliver
/// input report callbacks — the silent failure mode users complain about.
enum InputMonitoringPermission {
    enum Status {
        case granted
        case denied
        case unknown
    }

    static func status() -> Status {
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        switch access {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied:  return .denied
        default:                      return .unknown
        }
    }

    /// Trigger the system prompt. Only effective the first time the process asks;
    /// once denied the user must flip the switch manually in System Settings.
    @discardableResult
    static func request() -> Bool {
        return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}
