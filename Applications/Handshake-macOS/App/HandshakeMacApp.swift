import SwiftUI
import AppKit
import HandshakeCore

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: MacAppDelegate?
    var mainWindow: NSWindow?
    let viewModel = MacDashboardViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApplication.shared.setActivationPolicy(.regular)
        showMainWindow()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        showMainWindow()
    }

    func showMainWindow() {
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 580),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Handshake"
            window.minSize = NSSize(width: 640, height: 500)
            window.center()
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MacDashboardView(viewModel: viewModel))
            self.mainWindow = window
        }
        mainWindow?.orderFrontRegardless()
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        if viewModel.trustedDevices.isEmpty && !viewModel.isPairingSheetPresented {
            viewModel.startPairingFlow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }
}

@main
struct HandshakeMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Handshake", systemImage: "macbook.and.iphone") {
            MenuBarView(viewModel: appDelegate.viewModel, openMainWindow: {
                appDelegate.showMainWindow()
            })
        }
        .menuBarExtraStyle(.window)
    }
}

