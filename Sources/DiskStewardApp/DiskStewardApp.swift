import AppKit
import DiskStewardCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep Disk Steward running in the macOS menu bar after the full window is closed (REQ-001).
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
}

@main
struct DiskStewardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    init() {
        if CommandLine.arguments.contains("--version") || CommandLine.arguments.contains("-v") {
            print(DiskStewardVersion.displayString)
            Foundation.exit(0)
        }
    }

    var body: some Scene {
        Window("Disk Steward", id: "main") {
            MainWindowView()
                .environmentObject(appState)
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1220, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarPopoverView()
                .environmentObject(appState)
        } label: {
            Label {
                Text("Disk Steward")
            } icon: {
                Image(systemName: appState.menuBarSymbolName)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
