import AppKit
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let overlayController = OverlayController()
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        overlayController.start()
        statusItemController = StatusItemController(overlay: overlayController)
        if !launchedAsLoginItem, !overlayController.showMenuBarIcon {
            statusItemController?.restoreIconAndShow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlayController.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItemController?.restoreIconAndShow()
        return true
    }

    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == AEEventID(kAEOpenApplication)
            && event.attributeDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil
    }
}
