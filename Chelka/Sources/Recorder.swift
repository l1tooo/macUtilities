import AppKit
import AVFoundation
import ScreenCaptureKit

/// Запись экрана: весь экран или выделенная область, звук компьютера и, по желанию, микрофон.
/// Видео .mov сохраняется на Рабочий стол. Сама запись работает с macOS 15 (ScreenCaptureKit).
/// Окна Chelka в запись не попадают: ни панель, ни красная точка у выреза.
final class Recorder: ObservableObject {
    @Published private(set) var startedAt: Date?
    /// Запись запускается или сохраняется.
    @Published private(set) var busy = false
    /// Короткое сообщение под кнопками: ошибка или «Сохранено».
    @Published private(set) var message: String?
    @Published var microphone = UserDefaults.standard.bool(forKey: "recordMicrophone") {
        didSet { UserDefaults.standard.set(microphone, forKey: "recordMicrophone") }
    }

    /// От NotchController: свернуть панель перед выбором области и экран с вырезом.
    var collapse: (() -> Void)?
    var screen: (() -> NSScreen?)?

    var isRecording: Bool { startedAt != nil }

    static var isSupported: Bool {
        if #available(macOS 15, *) { return true }
        return false
    }

    private var session: AnyObject?
    private var selector: RegionSelector?
    private var messageTimer: Timer?

    func start(region: Bool) {
        guard #available(macOS 15, *), !isRecording, !busy, let screen = screen?() else { return }
        guard CGPreflightScreenCaptureAccess() else {
            // Откроет запрос macOS; после разрешения программу нужно перезапустить.
            CGRequestScreenCaptureAccess()
            show("Разреши Chelka запись экрана в Настройках и перезапусти её", seconds: 8)
            return
        }
        guard region else { return begin(screen: screen, rect: nil) }
        collapse?()
        let selector = RegionSelector(screen: screen) { [weak self] rect in
            guard let self else { return }
            self.selector = nil
            if let rect { self.begin(screen: screen, rect: rect) }
        }
        self.selector = selector
        selector.show()
    }

    func stop() {
        guard #available(macOS 15, *), let session = session as? RecordingSession, !busy else { return }
        busy = true
        Task { @MainActor in await session.stop() }
    }

    /// Для картинки в README: идёт запись 1 минуту 23 секунды.
    func setPreview(elapsed: TimeInterval) {
        startedAt = Date().addingTimeInterval(-elapsed)
    }

    @available(macOS 15, *)
    private func begin(screen: NSScreen, rect: CGRect?) {
        busy = true
        Task { @MainActor in
            var microphone = self.microphone
            if microphone, !(await Self.microphoneAllowed()) {
                microphone = false
                self.show("Нет доступа к микрофону, пишу без голоса")
            }
            do {
                let session = try await RecordingSession.start(
                    screen: screen, rect: rect, microphone: microphone, url: Self.newFileURL()
                ) { [weak self] result in
                    self?.finished(result)
                }
                self.session = session
                self.startedAt = Date()
            } catch {
                self.show("Запись не началась: \(error.localizedDescription)", seconds: 6)
            }
            self.busy = false
        }
    }

    private func finished(_ result: Result<URL, Error>) {
        session = nil
        startedAt = nil
        busy = false
        switch result {
        case .success(let url):
            show("Сохранено на Рабочий стол")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .failure(let error):
            show("Запись прервана: \(error.localizedDescription)", seconds: 6)
        }
    }

    private func show(_ text: String, seconds: TimeInterval = 4) {
        message = text
        messageTimer?.invalidate()
        messageTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.message = nil
        }
    }

    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// «Запись экрана 2026-11-10 в 17.30.12.mov», как называет macOS.
    private static func newFileURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'в' HH.mm.ss"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        return desktop.appendingPathComponent("Запись экрана \(formatter.string(from: Date())).mov")
    }
}

// MARK: - Сама запись (ScreenCaptureKit, macOS 15+)

@available(macOS 15, *)
private final class RecordingSession: NSObject, SCStreamDelegate, SCStreamOutput, SCRecordingOutputDelegate {
    enum Failure: LocalizedError {
        case noDisplay
        var errorDescription: String? { "экран не найден" }
    }

    private var stream: SCStream!
    private let url: URL
    private let onFinish: (Result<URL, Error>) -> Void
    private let queue = DispatchQueue(label: "local.Chelka.recording")
    private var done = false

    private init(url: URL, onFinish: @escaping (Result<URL, Error>) -> Void) {
        self.url = url
        self.onFinish = onFinish
    }

    static func start(screen: NSScreen, rect: CGRect?, microphone: Bool, url: URL,
                      onFinish: @escaping (Result<URL, Error>) -> Void) async throws -> RecordingSession {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw Failure.noDisplay
        }
        // Свои окна (панель, точка записи) в видео не нужны.
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])

        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        let area = rect ?? CGRect(origin: .zero, size: screen.frame.size)
        if let rect { config.sourceRect = rect }
        // Кодеку нужны чётные размеры.
        config.width = Int(area.width * scale) / 2 * 2
        config.height = Int(area.height * scale) / 2 * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = microphone

        let session = RecordingSession(url: url, onFinish: onFinish)
        session.stream = SCStream(filter: filter, configuration: config, delegate: session)

        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.outputFileType = .mov
        // H.264, а не HEVC: такое видео без проблем открывают мессенджеры и Windows.
        recording.videoCodecType = .h264

        // Пустые получатели кадров и звука: без них ScreenCaptureKit сыплет в журнал «output NOT found».
        try session.stream.addStreamOutput(session, type: .screen, sampleHandlerQueue: session.queue)
        try session.stream.addStreamOutput(session, type: .audio, sampleHandlerQueue: session.queue)
        if microphone {
            try session.stream.addStreamOutput(session, type: .microphone, sampleHandlerQueue: session.queue)
        }
        try session.stream.addRecordingOutput(SCRecordingOutput(configuration: recording, delegate: session))
        try await session.stream.startCapture()
        return session
    }

    func stop() async {
        do {
            try await stream.stopCapture()
        } catch {
            finish(.failure(error))
            return
        }
        // Обычно следом приходит recordingOutputDidFinishRecording; это — страховка.
        finishLater()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        finish(.success(url))
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        finish(.failure(error))
    }

    /// Поток остановился сам: например, запись выключили значком в строке меню.
    /// Файл к этому моменту может быть уже сохранён, поэтому ждём и смотрим, есть ли он.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        finishLater(error: error)
    }

    private func finishLater(error: Error? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            if FileManager.default.fileExists(atPath: url.path) {
                finish(.success(url))
            } else {
                finish(.failure(error ?? CocoaError(.fileWriteUnknown)))
            }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        DispatchQueue.main.async { [self] in
            guard !done else { return }
            done = true
            onFinish(result)
        }
    }
}

// MARK: - Выбор области

/// Затемняет экран, даёт выделить прямоугольник мышью. Esc или правый клик — отмена.
final class RegionSelector {
    private let window: NSWindow
    private let view: SelectionView
    private let previousApp = NSWorkspace.shared.frontmostApplication

    /// completion получает область в координатах экрана для ScreenCaptureKit (начало — левый верхний угол).
    init(screen: NSScreen, completion: @escaping (CGRect?) -> Void) {
        let frame = screen.frame
        window = KeyWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        view = SelectionView(frame: CGRect(origin: .zero, size: frame.size))
        window.contentView = view
        view.onFinish = { [weak self] rect in
            guard let self else { return }
            self.window.orderOut(nil)
            // Возвращаем фокус программе, в которой работали до выбора области.
            self.previousApp?.activate()
            completion(rect.map { r in
                CGRect(x: r.minX.rounded(), y: (frame.height - r.maxY).rounded(),
                       width: r.width.rounded(), height: r.height.rounded())
            })
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }
}

private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var selection: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(start.x - current.x), height: abs(start.y - current.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        guard let selection, selection.width > 0, selection.height > 0 else {
            hint("Выдели область мышью · Esc — отмена", at: NSPoint(x: bounds.midX, y: bounds.midY))
            return
        }
        NSColor.clear.setFill()
        selection.fill(using: .copy)
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
        hint("\(Int(selection.width)) × \(Int(selection.height))",
             at: NSPoint(x: selection.midX, y: max(selection.minY - 18, 14)))
    }

    private func hint(_ text: String, at center: NSPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let box = NSRect(x: center.x - size.width / 2 - 10, y: center.y - size.height / 2 - 5,
                         width: size.width + 20, height: size.height + 10)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + 10, y: box.minY + 5), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let selection, selection.width >= 20, selection.height >= 20 {
            onFinish?(selection)
        } else {
            // Случайный клик без выделения — даём попробовать ещё раз.
            start = nil
            current = nil
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) { onFinish?(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) }
    }
}
