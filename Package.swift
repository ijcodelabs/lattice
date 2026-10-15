// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lattice",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "lattice", targets: ["lattice"]),
        .executable(name: "lattice-ui", targets: ["lattice-ui"]),
        .library(name: "LatticeCore", targets: ["LatticeCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.0"),
    ],
    targets: [
        // Pure logic. Foundation only — no AppKit / ApplicationServices.
        .target(name: "LatticeCore"),
        // Strict YAML config → core settings. Separate target so the core stays Foundation-only.
        .target(name: "LatticeConfig", dependencies: ["LatticeCore", .product(name: "Yams", package: "Yams")]),
        // macOS edge: Accessibility API, worker threads, displays, permissions, hotkeys.
        .target(name: "LatticeAX", dependencies: ["LatticeCore"]),
        .executableTarget(name: "lattice", dependencies: ["LatticeCore", "LatticeAX", "LatticeConfig"]),
        // UI helper (which-key HUD, palette): separate process so a UI crash never touches window management.
        .executableTarget(name: "lattice-ui", dependencies: ["LatticeCore"]),
        .testTarget(name: "LatticeCoreTests", dependencies: ["LatticeCore"]),
        .testTarget(name: "LatticeConfigTests", dependencies: ["LatticeConfig", "LatticeCore"]),
    ],
    swiftLanguageModes: [.v6]
)
