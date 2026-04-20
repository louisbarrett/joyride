import SwiftUI
import AppKit

@main
struct JoyrideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    init() {
        // Hand the app state to the delegate so it can bring services up/down at the right time.
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(
                joyConManager: appState.joyConManager,
                profileStore: appState.profileStore,
                engine: appState.engine,
                openSettingsAction: {
                    openWindow(id: "mapping-editor")
                    NSApp.activate(ignoringOtherApps: true)
                }
            )
            .environmentObject(appState)
            .onAppear {
                // Bind the delegate to the state on first view appearance; App init runs before
                // the delegate is wired up via @NSApplicationDelegateAdaptor.
                appDelegate.appState = appState
            }
        } label: {
            // Using an SF Symbol keeps the menu bar icon template-style (adapts to light/dark).
            Image(systemName: "gamecontroller.fill")
        }
        .menuBarExtraStyle(.window)

        Window("Joyride — Mapping Editor", id: "mapping-editor") {
            MappingEditorView(
                profileStore: appState.profileStore,
                joyConManager: appState.joyConManager
            )
            .environmentObject(appState)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Joyride") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
            }
        }
    }
}
