// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DisplaySwitcher",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "DisplaySwitcher", targets: ["DisplaySwitcher"])
    ],
    targets: [
        .executableTarget(
            name: "DisplaySwitcher",
            path: "Sources/DisplaySwitcher",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("Network"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "DisplaySwitcherTests",
            dependencies: ["DisplaySwitcher"],
            path: "Tests/DisplaySwitcherTests"
        )
    ]
)
