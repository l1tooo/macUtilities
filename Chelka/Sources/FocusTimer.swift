import AppKit

/// Таймер. Пока он идёт или стоит на паузе, отсчёт виден рядом с вырезом даже в свёрнутом виде.
final class FocusTimer: ObservableObject {
    static let minMinutes = 1
    static let maxMinutes = 180

    /// Время, которое выбрано для следующего запуска. Запоминается между запусками программы.
    @Published var draftMinutes: Int {
        didSet {
            let clamped = min(max(draftMinutes, Self.minMinutes), Self.maxMinutes)
            if clamped != draftMinutes { draftMinutes = clamped }
            UserDefaults.standard.set(draftMinutes, forKey: "timerMinutes")
        }
    }
    @Published private(set) var endDate: Date?
    @Published private(set) var pausedRemaining: TimeInterval?
    @Published private(set) var remaining: TimeInterval = 0
    /// Таймер только что закончился: несколько секунд показываем «Готово».
    @Published private(set) var justFinished = false

    var isRunning: Bool { endDate != nil }
    var isPaused: Bool { pausedRemaining != nil }
    /// Таймер запущен (идёт или на паузе).
    var isActive: Bool { isRunning || isPaused }
    /// Нужно ли показывать отсчёт в свёрнутом виде.
    var isLive: Bool { isActive || justFinished }

    private var ticker: Timer?
    private var finishedHide: DispatchWorkItem?

    init() {
        let saved = UserDefaults.standard.integer(forKey: "timerMinutes")
        draftMinutes = saved > 0 ? saved : 25
    }

    func start() {
        run(for: TimeInterval(draftMinutes * 60))
    }

    func adjustDraft(by minutes: Int) {
        draftMinutes += minutes
    }

    func add(minutes: Int) {
        if let paused = pausedRemaining {
            pausedRemaining = paused + TimeInterval(minutes * 60)
            remaining = pausedRemaining ?? remaining
        } else if let endDate {
            self.endDate = endDate.addingTimeInterval(TimeInterval(minutes * 60))
            tick()
        }
    }

    func togglePause() {
        if let paused = pausedRemaining {
            run(for: paused)
        } else if let endDate {
            ticker?.invalidate()
            ticker = nil
            pausedRemaining = max(endDate.timeIntervalSinceNow, 1)
            remaining = pausedRemaining ?? 0
            self.endDate = nil
        }
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        finishedHide?.cancel()
        endDate = nil
        pausedRemaining = nil
        remaining = 0
        justFinished = false
    }

    private func run(for seconds: TimeInterval) {
        finishedHide?.cancel()
        justFinished = false
        pausedRemaining = nil
        endDate = Date().addingTimeInterval(seconds)
        tick()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        guard let endDate else { return }
        let left = endDate.timeIntervalSinceNow
        if left > 0 {
            remaining = left
            return
        }
        ticker?.invalidate()
        ticker = nil
        self.endDate = nil
        remaining = 0
        justFinished = true
        playSignal()
        let hide = DispatchWorkItem { [weak self] in self?.justFinished = false }
        finishedHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: hide)
    }

    /// Три коротких сигнала, чтобы точно услышать.
    private func playSignal() {
        for index in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.7) {
                // Копия, потому что один и тот же NSSound не играет второй раз, пока не доиграл первый.
                (NSSound(named: "Glass")?.copy() as? NSSound)?.play()
            }
        }
    }

    func setPreview(remaining: TimeInterval) {
        endDate = Date().addingTimeInterval(remaining)
        self.remaining = remaining
    }
}
