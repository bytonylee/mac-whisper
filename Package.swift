// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacWhisper",
    platforms: [
        // macOS 26 is required: NSGlassEffectView (Liquid Glass) only renders the
        // real frosted/refractive material when the app's deployment target is 26+.
        // With a lower target, macOS 26 falls back to a flat translucent-gray
        // compatibility appearance.
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "MacWhisper",
            path: "Sources"
        )
    ]
)
