import SwiftUI
import Darwin

@main
struct BookStreamApp: App {
    @StateObject private var model = AppModel()

    init() {
        // 无头模式：swift run BookStream --selftest | --parse <file> | --readframe <mp4>
        if CommandLine.arguments.contains("--selftest")
            || CommandLine.arguments.contains("--parse")
            || CommandLine.arguments.contains("--readframe") {
            Task {
                await SelfTest.run()
                exit(0)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
    }
}
