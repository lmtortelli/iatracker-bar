// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IAtrackerBar",
    defaultLocalization: "pt",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "IAtrackerBar", targets: ["IAtrackerBar"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", "6.29.0"..<"7.0.0"),
    ],
    targets: [
        // Lógica pura (modelos, banco, parsers, agregações) — testável sem UI.
        .target(
            name: "IAtrackerBarCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        // App de barra de menus (SwiftUI + AppKit).
        .executableTarget(
            name: "IAtrackerBar",
            dependencies: ["IAtrackerBarCore"]
        ),
        // As Command Line Tools não trazem XCTest: os testes são um executável
        // com um mini-harness próprio. Rode com `swift run iatracker-tests`.
        .executableTarget(
            name: "iatracker-tests",
            dependencies: ["IAtrackerBarCore"],
            path: "Tests",
            sources: ["IAtrackerBarTests"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
