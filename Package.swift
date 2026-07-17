// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "donts3p",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "donts3p", targets: ["donts3p"]),
        .executable(name: "donts3pRecoverySupervisor", targets: ["donts3pRecoverySupervisor"]),
    ],
    targets: [
        .target(
            name: "DontSleepShared",
            path: "Sources/DontSleepShared"
        ),
        .executableTarget(
            name: "donts3p",
            dependencies: ["DontSleepShared"],
            path: "Sources/DontSleepApp"
        ),
        .executableTarget(
            name: "donts3pRecoverySupervisor",
            dependencies: ["DontSleepShared"],
            path: "Sources/DontSleepSupervisor"
        ),
        .testTarget(
            name: "donts3pAppTests",
            dependencies: ["donts3p"],
            path: "Tests/DontSleepAppTests"
        ),
        .testTarget(
            name: "donts3pSupervisorTests",
            dependencies: ["donts3pRecoverySupervisor"],
            path: "Tests/DontSleepSupervisorTests"
        ),
    ]
)
