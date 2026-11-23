// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DeskCalendar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DeskCalendar"),
        .testTarget(name: "DeskCalendarTests", dependencies: ["DeskCalendar"])
    ]
)
