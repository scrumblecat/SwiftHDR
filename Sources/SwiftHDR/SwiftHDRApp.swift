import SwiftUI

@main
struct SwiftHDRApp: App {
    @StateObject private var viewModel = ConverterViewModel()

    var body: some Scene {
        WindowGroup("SwiftHDR") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 600, minHeight: 600)
        }
        .defaultSize(width: 680, height: 680)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Videos…") { viewModel.chooseInputFiles() }
                    .keyboardShortcut("o")
            }
        }
    }
}
