// swift-tools-version:5.9
// Engine self-tests that run on a Mac without Xcode:  cd SelfTest && swift run
import PackageDescription

let package = Package(
    name: "BaselineSelfTest",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../Core")],
    targets: [.executableTarget(name: "baseline-selftest", dependencies: [.product(name: "BaselineCore", package: "Core")])]
)
