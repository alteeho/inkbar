import AppKit
import Combine
import SwiftUI
import Carbon

@MainActor
final class StatusItemController: NSObject {
    private let overlay: OverlayController
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var hosting: NSHostingController<StatusPopoverView>?
    private var iconCancellable: AnyCancellable?
    private let restoreHotKey = RestoreHotKey()

    init(overlay: OverlayController) {
        self.overlay = overlay
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let root = StatusPopoverView(
            overlay: overlay,
            onAbout: { [weak self] in
                self?.showAbout()
            },
            onQuit: {
                NSApp.terminate(nil)
            },
            onHideIcon: { [weak self] in
                self?.confirmHideIcon()
            }
        )
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = [.preferredContentSize, .intrinsicContentSize]
        hosting = controller

        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = true
        configureGlass(for: controller)

        if let button = statusItem.button {
            button.title = ""
            button.image = StatusItemController.icon()
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "Inkbar"
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        iconCancellable = overlay.$showMenuBarIcon
            .removeDuplicates()
            .sink { [weak self] show in
                self?.applyIconVisibility(show)
            }
        applyIconVisibility(overlay.showMenuBarIcon)

        restoreHotKey.onPressed = { [weak self] in
            self?.restoreIconAndShow()
        }
        restoreHotKey.register()
    }

    func handleReopen() {
        restoreIconAndShow()
    }

    func restoreIconAndShow() {
        overlay.showMenuBarIcon = true
        applyIconVisibility(true)
        DispatchQueue.main.async { [weak self] in
            self?.showPopover()
        }
    }

    private func confirmHideIcon() {
        closePopover()
        NSApp.activate(ignoringOtherApps: true)
        let language = LanguageSettings.shared
        let alert = NSAlert()
        alert.messageText = language.t("hideIcon.alert.title")
        alert.informativeText = language.t("hideIcon.alert.body")
        alert.alertStyle = .informational
        alert.addButton(withTitle: language.t("hideIcon.alert.confirm"))
        alert.addButton(withTitle: language.t("hideIcon.alert.cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            overlay.showMenuBarIcon = false
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard overlay.showMenuBarIcon, let button = statusItem.button, statusItem.isVisible else { return }
        configureGlass(for: hosting)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func closePopover() {
        popover.performClose(nil)
    }

    private func applyIconVisibility(_ show: Bool) {
        statusItem.isVisible = show
        NSApp.setActivationPolicy(.accessory)
        if !show {
            closePopover()
        }
    }

    private func configureGlass(for controller: NSHostingController<StatusPopoverView>?) {
        guard let view = controller?.view else { return }
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        if MacGlass.isLiquid {
            popover.appearance = nil
        }
    }

    private func showAbout() {
        closePopover()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        let language = LanguageSettings.shared
        alert.messageText = "Inkbar"
        alert.informativeText = language.format(
            "about.body",
            Bundle.main.shortVersion,
            Bundle.main.buildVersion
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: language.t("ok"))
        alert.runModal()
    }

    static func icon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let line: CGFloat = 1.2
            let glyph = NSSize(width: 17, height: 11)
            var frame = NSRect(
                x: rect.midX - glyph.width / 2,
                y: rect.midY - glyph.height / 2,
                width: glyph.width,
                height: glyph.height
            )
            frame = frame.insetBy(dx: line / 2, dy: line / 2)
            let radius = frame.height * 0.17

            let outline = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
            outline.lineWidth = line
            outline.lineJoinStyle = .round
            outline.lineCapStyle = .round
            NSColor.black.setStroke()
            outline.stroke()

            let notchW = frame.width * 0.19
            let notchH = max(1.6, frame.height * 0.17)
            let notch = NSRect(
                x: frame.midX - notchW / 2,
                y: frame.maxY - notchH,
                width: notchW,
                height: notchH
            )
            NSColor.black.setFill()
            NSBezierPath(roundedRect: notch, xRadius: notchH / 2, yRadius: notchH / 2).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// System-wide hotkey that does not need Accessibility permission.
final class RestoreHotKey {
    var onPressed: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func register() {
        var hotKeyID = EventHotKeyID(signature: OSType(0x4E4C5353), id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_N),
            UInt32(controlKey | optionKey | cmdKey),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let hotKey = Unmanaged<RestoreHotKey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    hotKey.onPressed?()
                }
                return noErr
            },
            1,
            &spec,
            userData,
            &handlerRef
        )
    }
}
