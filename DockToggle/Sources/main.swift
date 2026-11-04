// DockToggle — повторный клик по иконке активного приложения в Доке прячет его (как ⌘H).
// Работает через перехват кликов мыши (CGEventTap) и Accessibility API Дока.

import AppKit
import ApplicationServices
import ServiceManagement

final class DockToggle: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var eventTap: CFMachPort?
    private var swallowNextMouseUp = false
    private var permissionTimer: Timer?
    private let systemWide = AXUIElementCreateSystemWide()
    private var enabled = true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "enabled")
            rebuildMenu()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.object(forKey: "enabled") != nil {
            enabled = UserDefaults.standard.bool(forKey: "enabled")
        }
        AXUIElementSetMessagingTimeout(systemWide, 0.25)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "dock.arrow.down.rectangle", accessibilityDescription: "DockToggle") {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "⇩"
        }
        statusItem = item
        rebuildMenu()

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            startTap()
        } else {
            // Ждём, пока пользователь выдаст доступ в «Универсальном доступе».
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.startTap()
                self?.rebuildMenu()
            }
        }
    }

    // MARK: - Перехват кликов

    private func startTap() {
        guard eventTap == nil else { return }
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<DockToggle>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("DockToggle: не удалось создать event tap (нет доступа?)")
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown:
            // Клик с модификаторами (⌘, ⌥, ⌃, ⇧) не трогаем — у Дока на них свои действия.
            let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            if enabled, event.flags.intersection(modifiers).isEmpty,
               let app = frontmostAppClickedInDock(at: event.location) {
                swallowNextMouseUp = true
                DispatchQueue.main.async { app.hide() }
                return nil
            }
        case .leftMouseUp:
            if swallowNextMouseUp {
                swallowNextMouseUp = false
                return nil
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// Возвращает активное приложение, если клик пришёлся на его же иконку в Доке
    /// и у него есть видимые окна. Иначе nil — клик уходит в Док как обычно.
    private func frontmostAppClickedInDock(at point: CGPoint) -> NSRunningApplication? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let frontURL = front.bundleURL,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }

        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let element = hit else { return nil }

        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == dock.processIdentifier else { return nil }
        guard attribute(element, kAXSubroleAttribute) as? String == "AXApplicationDockItem" else { return nil }
        guard let itemURL = attribute(element, kAXURLAttribute) as? URL,
              normalizedPath(itemURL) == normalizedPath(frontURL) else { return nil }

        // Нет окон на экране (всё свёрнуто, окно на другом рабочем столе, у Finder нет окон) —
        // пусть Док сам откроет или развернёт окно.
        guard hasOnScreenWindows(pid: front.processIdentifier) else { return nil }
        return front
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func hasOnScreenWindows(pid: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return true }
        return windows.contains { info in
            (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                && (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        }
    }

    // MARK: - Меню в строке меню

    private func rebuildMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()

        if !AXIsProcessTrusted() {
            let ax = menu.addItem(withTitle: "Дать доступ в «Универсальном доступе»…",
                                  action: #selector(openAccessibilitySettings), keyEquivalent: "")
            ax.target = self
            menu.addItem(.separator())
        }

        let toggle = menu.addItem(withTitle: "Прятать повторным кликом", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = enabled ? .on : .off

        let login = menu.addItem(withTitle: "Запускать при входе", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off

        menu.addItem(.separator())
        menu.addItem(withTitle: "Выйти из DockToggle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
        statusItem.button?.appearsDisabled = !enabled
    }

    @objc private func toggleEnabled() { enabled.toggle() }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не получилось изменить автозапуск"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        rebuildMenu()
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

let app = NSApplication.shared
let delegate = DockToggle()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
