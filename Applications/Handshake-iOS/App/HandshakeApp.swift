import SwiftUI
import HandshakeCore

@main
struct HandshakeIOSApp: App {
    @StateObject private var viewModel = DashboardViewModel()

    var body: some Scene {
        WindowGroup {
            iPhoneDashboardView(viewModel: viewModel)
        }
    }
}

