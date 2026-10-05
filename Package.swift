// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BandejaIA",
    defaultLocalization: "pt",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "BandejaIA", targets: ["BandejaIA"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", "6.29.0"..<"7.0.0"),
    ],
    targets: [
        // Lógica pura (modelos, banco, parsers, agregações) — testável sem UI.
        .target(
            name: "BandejaIACore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        // App de barra de menus (SwiftUI + AppKit).
        .executableTarget(
            name: "BandejaIA",
            dependencies: ["BandejaIACore"]
        ),
        // As Command Line Tools não trazem XCTest: os testes são um executável
        // com um mini-harness próprio. Rode com `swift run bandeja-tests`.
        .executableTarget(
            name: "bandeja-tests",
            dependencies: ["BandejaIACore"],
            path: "Tests",
            sources: ["BandejaIATests"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
