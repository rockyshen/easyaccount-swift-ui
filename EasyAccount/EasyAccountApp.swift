import SwiftUI

@main
struct EasyAccountApp: App {
    @StateObject private var viewModel = EasyAccountViewModel()

    var body: some Scene {
        WindowGroup {
            EasyAccountRootView()
                .environmentObject(viewModel)
                .preferredColorScheme(viewModel.appearanceMode.preferredColorScheme)
        }
    }
}
