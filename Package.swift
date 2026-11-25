// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Registratore",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Registratore",
            path: "Sources/Registratore"
        )
    ]
)
