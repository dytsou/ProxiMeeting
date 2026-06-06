// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ProxiMeeting",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ProxiMeeting", targets: ["ProxiMeeting"])
    ],
    targets: [
        .executableTarget(
            name: "ProxiMeeting",
            path: "ProxiMeeting",
            exclude: [
                "Info.plist",
                "ProxiMeeting.entitlements",
                "Assets.xcassets",
                "en.lproj",
                "zh-Hant.lproj"
            ],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("EventKit")
            ]
        )
    ]
)
