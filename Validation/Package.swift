// swift-tools-version:5.9
// Runs the engines over real Fitbit data from LifeSnaps:  python3 prepare.py && swift run -c release && python3 report.py
import PackageDescription

let package = Package(
    name: "Validation",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../Core")],
    targets: [.executableTarget(name: "validate", dependencies: [.product(name: "BaselineCore", package: "Core")])]
)
