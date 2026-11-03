// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GreywallNetworkExperiment",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "network-probe", targets: ["NetworkProbe"]),
        .library(name: "FilterPrototype", targets: ["FilterPrototype"]),
        .library(name: "NetworkPolicy", targets: ["NetworkPolicy"]),
    ],
    targets: [
        .target(name: "ProcessInfoShim", linkerSettings: [.linkedLibrary("bsm")]),
        .target(name: "NetworkPolicy", dependencies: ["ProcessInfoShim"]),
        .target(name: "FilterPrototype", dependencies: ["NetworkPolicy", "ProcessInfoShim"],
                linkerSettings: [.linkedFramework("NetworkExtension")]),
        .executableTarget(name: "NetworkProbe", dependencies: ["NetworkPolicy"],
                linkerSettings: [.linkedFramework("NetworkExtension")]),
        .testTarget(name: "NetworkPolicyTests", dependencies: ["NetworkPolicy"]),
    ]
)
