import AppKit

/// Runs launch work once the app is up, independent of which windows macOS restores.
/// (A view's `.task` never runs if state restoration brings back only the subtitle window.)
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onLaunch: (@MainActor () async -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let onLaunch else { return }
        Task { @MainActor in await onLaunch() }
    }
}
