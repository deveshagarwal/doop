// swift-tools-version:5.9
// Exposes the platform-neutral Core as a library so the engines can be tested on a Mac
// without Xcode (see ../SelfTest). The iOS app compiles these same sources via project.yml.
import PackageDescription

let package = Package(
    name: "BaselineCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "BaselineCore", targets: ["BaselineCore"])],
    targets: [.target(name: "BaselineCore", path: ".", exclude: ["Package.swift"])]
)
