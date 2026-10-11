// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ProxiMeeting",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ProxiMeetingCore", targets: ["ProxiMeetingCore"]),
        .executable(name: "ProxiMeeting", targets: ["ProxiMeeting"])
    ],
    targets: [
        .target(
            name: "ProxiMeetingCore",
            path: "ProxiMeeting",
            exclude: [
                "Info.plist",
                "ProxiMeeting.entitlements",
                "Assets.xcassets",
                "en.lproj",
                "zh-Hant.lproj",
                "screenshot.jpg",
                "AppDebug.swift",
                "AppearanceStore.swift",
                "CalendarManager.swift",
                "CalendarSelectionStore.swift",
                "JoinPreferenceStore.swift",
                "MeetingMenuView.swift",
                "ProxiMeetingApp.swift",
                "String+HalfwidthPrefix.swift",
                "UpdateChecker.swift"
            ],
            sources: ["MeetingDayWindow.swift"]
        ),
        .executableTarget(
            name: "ProxiMeeting",
            dependencies: ["ProxiMeetingCore"],
            path: "ProxiMeeting",
            exclude: [
                "Info.plist",
                "ProxiMeeting.entitlements",
                "Assets.xcassets",
                "en.lproj",
                "zh-Hant.lproj",
                "MeetingDayWindow.swift",
                "screenshot.jpg"
            ],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("EventKit")
            ]
        ),
        .testTarget(
            name: "ProxiMeetingTests",
            dependencies: ["ProxiMeetingCore"],
            path: "Tests/ProxiMeetingTests"
        )
    ]
)
