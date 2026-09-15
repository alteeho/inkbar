import AppKit
import CoreGraphics

extension NSScreen {
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return deviceDescription[key] as? CGDirectDisplayID ?? 0
    }

    var isBuiltin: Bool {
        CGDisplayIsBuiltin(displayID) != 0
    }

    var hasNotch: Bool {
        safeAreaInsets.top > 0 && auxiliaryTopLeftArea != nil
    }

    /// Height of the camera housing / menu-bar strip.
    var menuBarOverlayHeight: CGFloat {
        let notch = safeAreaInsets.top
        let inferred = frame.maxY - visibleFrame.maxY
        return max(notch, inferred, 24)
    }

    var menuBarOverlayFrame: CGRect {
        CGRect(
            x: frame.minX,
            y: frame.maxY - menuBarOverlayHeight,
            width: frame.width,
            height: menuBarOverlayHeight
        )
    }
}
