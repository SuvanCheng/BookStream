// swift-tools-version:6.0
// BookStream —— macOS 原生离线有声书/字幕视频生成器（Swift 6 严格并发模式）

import PackageDescription

let package = Package(
    name: "BookStream",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "BookStream",
            path: "Sources/BookStream",
            swiftSettings: [
                // 显式锁定 Swift 6 语言模式（Strict Concurrency）
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
