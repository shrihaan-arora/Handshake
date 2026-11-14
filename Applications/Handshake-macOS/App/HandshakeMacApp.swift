import SwiftUI
import HandshakeCore

@main
struct HandshakeMacApp: App {
    @StateObject private var viewModel = MacDashboardViewModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("Handshake", id: "main-dashboard") {
            MacDashboardView(viewModel: viewModel)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 720, height: 560)

        MenuBarExtra("Handshake", systemImage: "macbook.and.iphone") {
            MenuBarView(viewModel: viewModel) {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "main-dashboard")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
