// swift-tools-version:5.10
import PackageDescription

let ndiLib = "/Library/NDI SDK for Apple/lib/macOS"

let package = Package(
    name: "WBWrite",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(name: "CNDI", path: "Sources/CNDI"),
        .executableTarget(
            name: "WBWrite",
            dependencies: ["CNDI"],
            path: "Sources/WBWrite",
            linkerSettings: [
                .unsafeFlags([
                    "-L", ndiLib,
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", ndiLib,
                ]),
            ]
        ),
    ]
)
