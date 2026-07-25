// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "KiwiPet",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "KiwiPet", targets: ["KiwiPet"])
    ],
    targets: [
        .executableTarget(
            name: "KiwiPet",
            path: "Sources/KiwiPet"
        ),
        .testTarget(
            name: "KiwiPetTests",
            dependencies: ["KiwiPet"],
            path: "Tests/KiwiPetTests"
        )
    ]
)
