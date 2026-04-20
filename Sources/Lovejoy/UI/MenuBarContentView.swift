import SwiftUI

/// Popover shown from the menu bar icon. Gives at-a-glance status and quick profile switching.
struct MenuBarContentView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var joyConManager: JoyConManager
    @ObservedObject var profileStore: ProfileStore
    @ObservedObject var engine: MappingEngine

    var openSettingsAction: () -> Void

    @State private var showDiagnostics: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            permissionSection
            Divider()
            devicesSection
            Divider()
            pipelineSection
            Divider()
            profileSection
            if showDiagnostics {
                Divider()
                diagnosticsSection
            }
            Divider()
            HStack {
                Button {
                    openSettingsAction()
                } label: {
                    Label("Open Mapping Editor…", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                Button {
                    showDiagnostics.toggle()
                } label: {
                    Image(systemName: showDiagnostics ? "ladybug.fill" : "ladybug")
                }
                .buttonStyle(.bordered)
                .help("Toggle diagnostic log")

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 4) {
                Spacer()
                Text("Lovejoy \(AppBundle.versionString) · built \(AppBundle.buildStamp)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            Image(systemName: "gamecontroller.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Lovejoy").font(.headline)
                Text("Joy-Con Input Mapper").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $app.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    @ViewBuilder
    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            permissionRow(
                granted: app.hasAccessibilityPermission,
                title: "Accessibility",
                missingDescription: "Required to send keyboard, mouse, and scroll events to other apps.",
                grantedDescription: "Event injection is enabled.",
                action: { AccessibilityPermission.requestAndOpenSettingsIfNeeded() }
            )
            permissionRow(
                granted: app.inputMonitoringStatus == .granted,
                title: "Input Monitoring",
                missingDescription: "Required to read button presses and stick movement from the Joy-Con. macOS blocks HID reports until this is granted.",
                grantedDescription: "HID reports from controllers will be delivered.",
                action: {
                    InputMonitoringPermission.request()
                    InputMonitoringPermission.openSettings()
                }
            )
        }
    }

    @ViewBuilder
    private func permissionRow(granted: Bool,
                               title: String,
                               missingDescription: String,
                               grantedDescription: String,
                               action: @escaping () -> Void) -> some View {
        if granted {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(title) granted").font(.caption.bold())
                    Text(grantedDescription).font(.caption2).foregroundStyle(.secondary)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(title) permission needed").font(.subheadline.bold())
                    Text(missingDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Button("Open System Settings…", action: action)
                            .controlSize(.small)
                        Button {
                            AppBundle.revealInFinder()
                        } label: {
                            Label("Reveal App", systemImage: "folder")
                        }
                        .controlSize(.small)
                        .help("Reveal Lovejoy.app in Finder so you can drag it into the privacy list")
                        Button {
                            AppBundle.copyPathToClipboard()
                        } label: {
                            Label("Copy Path", systemImage: "doc.on.clipboard")
                        }
                        .controlSize(.small)
                        .help("Copy the Lovejoy.app path. In the + dialog in System Settings press ⇧⌘G and paste.")
                    }
                    Text("If Lovejoy isn't shown in the list, click the + button there, press ⇧⌘G, paste the path, and enable it.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Connected Controllers")
                    .font(.subheadline.bold())
                Spacer()
                Button {
                    app.rescanControllers()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Rescan for controllers")

                Button {
                    BluetoothSettings.openPairingPane()
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .help("Open Bluetooth settings to pair a new controller")
            }
            if joyConManager.devices.isEmpty {
                Text("No Joy-Cons detected. Pair one via Bluetooth settings (hold the small sync button on the side of the Joy-Con until the four LEDs scan). If already paired, make sure Input Monitoring is granted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                DeviceRowsLiveList(joyConManager: joyConManager, liveInput: joyConManager.liveInput)
            }
        }
    }

    private var pipelineSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Pipeline").font(.subheadline.bold())
                Spacer()
                Button {
                    engine.injectTestScroll()
                } label: {
                    Label("Test Scroll", systemImage: "waveform")
                }
                .controlSize(.small)
                .help("Synthesizes 10 scroll-down events. If nothing happens, Accessibility permission is missing.")
            }
            PipelineStatsRow(liveInput: joyConManager.liveInput, engine: engine)
            PipelineGuidance(app: app, liveInput: joyConManager.liveInput, engine: engine)
        }
    }

    @ViewBuilder
    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Diagnostics").font(.subheadline.bold())

            Text("HID").font(.caption2.bold()).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if joyConManager.diagnostics.isEmpty {
                        Text("No HID events yet.").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(joyConManager.diagnostics.enumerated().reversed()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 100)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))

            Text("Dispatched actions").font(.caption2.bold()).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if engine.dispatchedActions.isEmpty {
                        Text("No actions dispatched yet.").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(engine.dispatchedActions.enumerated().reversed()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 100)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
        }
    }

    private struct PipelineStat: View {
        let label: String
        let value: Int
        let tint: Color

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Text("\(value)")
                    .font(.callout.monospaced().bold())
                    .foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Standalone view so that device rows rebuild at the `liveInput` flush rate (~30 Hz)
    /// without dragging the entire popover body along with them.
    private struct DeviceRowsLiveList: View {
        @ObservedObject var joyConManager: JoyConManager
        @ObservedObject var liveInput: JoyConLiveInput

        var body: some View {
            ForEach(joyConManager.devices, id: \.identifier) { device in
                DeviceRow(device: device,
                          state: liveInput.states[device.identifier],
                          reportCount: liveInput.reportCounts[device.identifier] ?? 0)
            }
        }
    }

    /// Isolates the per-tick pipeline stats from the rest of the popover. Observes both
    /// the throttled HID counts and the throttled cursor-move counter.
    private struct PipelineStatsRow: View {
        @ObservedObject var liveInput: JoyConLiveInput
        @ObservedObject var engine: MappingEngine

        var body: some View {
            let totalReports = liveInput.reportCounts.values.reduce(0, +)
            HStack(spacing: 10) {
                PipelineStat(label: "HID reports", value: totalReports, tint: totalReports > 0 ? .green : .orange)
                PipelineStat(label: "Button events", value: engine.buttonEventCount, tint: engine.buttonEventCount > 0 ? .green : .secondary)
                PipelineStat(label: "Cursor moves", value: engine.cursorMoveCount, tint: engine.cursorMoveCount > 0 ? .green : .secondary)
            }
        }
    }

    /// Conditional guidance messages under the pipeline stats. Pulled into its own view
    /// so its re-renders don't invalidate the stat row above.
    private struct PipelineGuidance: View {
        @ObservedObject var app: AppState
        @ObservedObject var liveInput: JoyConLiveInput
        @ObservedObject var engine: MappingEngine

        var body: some View {
            let totalReports = liveInput.reportCounts.values.reduce(0, +)
            VStack(alignment: .leading, spacing: 4) {
                if totalReports > 0 && engine.buttonEventCount == 0 && engine.cursorMoveCount == 0 {
                    Text("Reports arriving but no events yet — press a button or nudge a stick past the deadzone.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !app.hasAccessibilityPermission && (engine.buttonEventCount > 0 || engine.cursorMoveCount > 0) {
                    Text("Events are firing but Accessibility is not granted — CGEvent.post() is a silent no-op until you grant it.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Active Profile").font(.subheadline.bold())
            Picker("Profile", selection: Binding(
                get: { profileStore.activeProfileID },
                set: { profileStore.setActive($0) }
            )) {
                ForEach(profileStore.profiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }
}

private struct DeviceRow: View {
    let device: JoyConDevice
    let state: JoyConInputState?
    let reportCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.side.displayName).font(.caption.bold())
                HStack(spacing: 6) {
                    Circle()
                        .fill(reportCount > 0 ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(reportCount > 0 ? "Live (\(reportCount) reports)" : "Paired, waiting for input…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let state = state, reportCount > 0 {
                BatteryBadge(level: state.batteryLevel)
            }
        }
    }

    private var iconName: String {
        switch device.side {
        case .left: return "l.joystick.fill"
        case .right: return "r.joystick.fill"
        case .proController: return "gamecontroller.fill"
        case .unknown: return "gamecontroller"
        }
    }
}

private struct BatteryBadge: View {
    let level: UInt8

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
            Text(label)
        }
        .font(.caption2)
        .foregroundStyle(color)
    }

    private var iconName: String {
        switch level {
        case 0, 1: return "battery.0"
        case 2, 3: return "battery.25"
        case 4, 5: return "battery.50"
        case 6, 7: return "battery.75"
        default: return "battery.100"
        }
    }

    private var color: Color {
        switch level {
        case 0, 1: return .red
        case 2, 3: return .orange
        default: return .secondary
        }
    }

    private var label: String {
        // The raw field is packed as a 4-bit value where ~8 = full, ~0 = critical.
        let pct = min(100, Int(Double(level) / 8.0 * 100.0))
        return "\(pct)%"
    }
}
