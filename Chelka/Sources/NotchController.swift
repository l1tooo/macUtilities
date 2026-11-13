import AppKit
import SwiftUI

enum Layout {
    static let expandedSize = CGSize(width: 680, height: 200)
    /// Нижняя строка с зарядом Bluetooth-устройств (есть, только если они подключены).
    static let footerHeight: CGFloat = 28
    /// Окно чуть больше раскрытой панели, чтобы влезли нижняя строка и тень.
    static let windowSize = CGSize(width: 740, height: 260)

    static func expandedSize(footer: Bool) -> CGSize {
        CGSize(width: expandedSize.width, height: expandedSize.height + (footer ? footerHeight : 0))
    }

    /// Насколько «чёлка» расширяется в каждую сторону, когда идёт запись экрана.
    static let liveWing: CGFloat = 64

    /// Размер свёрнутой формы. Обычно чуть меньше настоящего выреза, чтобы её не было видно;
    /// во время записи — шире, по бокам красная точка и время.
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
    let calculator = Calculator()
    let recorder = Recorder()
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
    /// Подписки на движение мыши (глобальная и внутри своего окна).
    private var mouseMonitors: [Any] = []
    /// Однократный таймер паузы перед раскрытием.
    private var dwellTimer: Timer?
    /// Опрос мыши только пока панель раскрыта: следим, когда мышь уйдёт.
    private var expandedTimer: Timer?

    func start() {
        panel.contentView = FirstMouseHostingView(rootView: NotchRoot(model: model))
        layout()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.layout() }

        // В свёрнутом виде ничего не опрашиваем: macOS сама сообщает о движении мыши.
        // Для событий мыши (в отличие от клавиатуры) разрешения не нужны.
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.mouseMoved()
        }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.mouseMoved()
            return event
        }) {
            mouseMonitors.append(local)
        }

        model.recorder.collapse = { [weak self] in self?.setExpanded(false) }
        model.recorder.screen = { [weak self] in self?.screen }

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

    /// Мышь сдвинулась (в свёрнутом виде). Если она над вырезом — ждём 0,12 с и раскрываем.
    private func mouseMoved() {
        guard !model.expanded else { return }
        if mouseInHotZone() {
            guard dwellTimer == nil else { return }
            // Пауза, чтобы панель не выскакивала, когда мышь просто пролетает мимо.
            // Отдельный таймер нужен, потому что если мышь замрёт, новых событий не будет.
            dwellTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.dwellTimer = nil
                if !self.model.expanded, self.mouseInHotZone() { self.setExpanded(true) }
            }
        } else {
            dwellTimer?.invalidate()
            dwellTimer = nil
        }
    }

    /// Пока панель раскрыта, 20 раз в секунду проверяем, не ушла ли мышь.
    /// Над своим неактивным окном события движения приходят ненадёжно, поэтому здесь опрос.
    private func checkMouseLeft() {
        guard let screen else { return }
        let size = Layout.expandedSize(footer: !model.system.bluetooth.isEmpty)
        let w = size.width + 24
        let h = size.height + 16
        let keep = NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h)
        if !contains(keep, NSEvent.mouseLocation) { setExpanded(false) }
    }

    private func mouseInHotZone() -> Bool {
        guard let screen else { return false }
        let collapsed = Layout.collapsedSize(notch: model.notchSize, live: model.recorder.isRecording)
        let w = max(collapsed.width, model.notchSize.width) + 16
        let h = model.notchSize.height
        let hot = NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h)
        return contains(hot, NSEvent.mouseLocation)
    }

    /// NSRect.contains не включает верхний край, а мышь у края экрана стоит ровно на нём.
    private func contains(_ rect: NSRect, _ point: NSPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }

    private func setExpanded(_ expanded: Bool) {
        dwellTimer?.invalidate()
        dwellTimer = nil
        expandedTimer?.invalidate()
        expandedTimer = nil
        model.expanded = expanded
        model.system.active = expanded
        panel.ignoresMouseEvents = !expanded
        if expanded {
            expandedTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                self?.checkMouseLeft()
            }
        }
    }
}
