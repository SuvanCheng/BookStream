import SwiftUI
import Darwin

extension Notification.Name {
    static let bookStreamPickFile = Notification.Name("BookStream.pickFile")
    static let bookStreamReloadFile = Notification.Name("BookStream.reloadFile")
    static let bookStreamStartExport = Notification.Name("BookStream.startExport")
    static let bookStreamCancelExport = Notification.Name("BookStream.cancelExport")
}

@main
struct BookStreamApp: App {
    @StateObject private var model = AppModel()

    init() {
        // 监听应用退出通知（Cmd+Q、Dock 退出、系统关机等），确保所有后台子进程被即时全部终止，不残留孤儿进程
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            KokoroTTS.terminateAllActiveSubprocesses()
            EdgeTTS.terminateAllActiveSubprocesses()
        }

        // 无头模式：swift run BookStream --selftest | --parse <file> | --readframe <mp4>
        if CommandLine.arguments.contains("--selftest")
            || CommandLine.arguments.contains("--parse")
            || CommandLine.arguments.contains("--readframe")
            || CommandLine.arguments.contains("--check-drift") {
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
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("导入书籍 / 字幕文件...") {
                    NotificationCenter.default.post(name: .bookStreamPickFile, object: nil)
                }
                .keyboardShortcut("i", modifiers: .command)

                Button("重新解析当前文件") {
                    NotificationCenter.default.post(name: .bookStreamReloadFile, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.inputURL == nil)

                Divider()

                Button("开始生成导出") {
                    NotificationCenter.default.post(name: .bookStreamStartExport, object: nil)
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.inputKind == nil || model.isProcessing)

                Button("取消导出") {
                    NotificationCenter.default.post(name: .bookStreamCancelExport, object: nil)
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.isProcessing)
            }

            CommandMenu("日志") {
                Button("复制全部日志") {
                    model.copyLog()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("清空运行日志") {
                    model.logLines.removeAll()
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }
    }
}
