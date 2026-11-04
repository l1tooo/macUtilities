import AppKit
import SwiftUI

enum Layout {
    static let expandedSize = CGSize(width: 680, height: 200)
    /// Окно чуть больше раскрытой панели, чтобы влезла тень.
    static let windowSize = CGSize(width: 740, height: 232)
    /// Насколько «чёлка» расширяется в каждую сторону, когда идёт таймер.
    static let liveWing: CGFloat = 64

    /// Размер свёрнутой формы. Без таймера она чуть меньше настоящего выреза, чтобы её не было видно.
    static func collapsedSize(notch: CGSize, live: Bool) -> CGSize {
        live
            ? CGSize(width: notch.width + liveWing * 2, height: notch.height)
            : CGSize(width: max(notch.width - 6, 40), height: max(notch.height - 2, 10))
    }
}

final class NotchModel: ObservableObject {
    @Published var expanded = false
    @Published var notchSize = CGSize(width: 185, height: 32)

    let system = SystemFeed()
    let timer = FocusTimer()
}

/// Окно без рамки поверх строки меню. Не забирает фокус у приложений.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Кнопки срабатывают с первого клика, даже если окно не активно.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

enum NotchGeometry {
    /// Экран с вырезом (встроенный дисплей MacBook), иначе главный экран.
    static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    static func notchSize(on screen: NSScreen) -> CGSize {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            return CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        }
        // Экран без выреза: рисуем «чёлку» высотой со строку меню.
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return CGSize(width: 185, height: max(menuBar, 24))
    }
}

final class NotchController {
    let model = NotchModel()
    private let panel = NotchPanel()
    private var screen: NSScreen?
    private var timer: Timer?
    private var hoverStart: Date?

    func start() {
        panel.contentView = FirstMouseHostingView(rootView: NotchRoot(model: model))
        layout()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.layout() }

        // Положение мыши опрашиваем сами: так не нужны никакие разрешения.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.tick() }

        model.system.start()
    }

    private func layout() {
        guard let screen = NotchGeometry.notchScreen() else { return }
        self.screen = screen
        model.notchSize = NotchGeometry.notchSize(on: screen)
        let size = Layout.windowSize
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2,
                              y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height),
                       display: true)
    }

    private func tick() {
        guard let screen else { return }
        let mouse = NSEvent.mouseLocation
        let top = screen.frame.maxY

        if model.expanded {
            let w = Layout.expandedSize.width + 24
            let h = Layout.expandedSize.height + 16
            let keep = NSRect(x: screen.frame.midX - w / 2, y: top - h, width: w, height: h)
            if !contains(keep, mouse) { setExpanded(false) }
        } else {
            let collapsed = Layout.collapsedSize(notch: model.notchSize, live: model.timer.isLive)
            let w = max(collapsed.width, model.notchSize.width) + 16
            let h = model.notchSize.height
            let hot = NSRect(x: screen.frame.midX - w / 2, y: top - h, width: w, height: h)
            if contains(hot, mouse) {
                // Короткая задержка, чтобы панель не выскакивала, когда мышь просто пролетает мимо.
                if let start = hoverStart {
                    if Date().timeIntervalSince(start) > 0.12 { setExpanded(true) }
                } else {
                    hoverStart = Date()
                }
            } else {
                hoverStart = nil
            }
        }
    }

    /// NSRect.contains не включает верхний край, а мышь у края экрана стоит ровно на нём.
    private func contains(_ rect: NSRect, _ point: NSPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }

    private func setExpanded(_ expanded: Bool) {
        hoverStart = nil
        model.expanded = expanded
        model.system.active = expanded
        panel.ignoresMouseEvents = !expanded
    }
}
