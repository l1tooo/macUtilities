import AppKit
import SwiftUI

/// Чёрная форма: верх ровный (прилегает к краю экрана), низ скруглён.
struct NotchShape: Shape {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct NotchRoot: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var timer: FocusTimer

    init(model: NotchModel) {
        self.model = model
        self.timer = model.timer
    }

    private var size: CGSize {
        model.expanded ? Layout.expandedSize : Layout.collapsedSize(notch: model.notchSize, live: timer.isLive)
    }

    var body: some View {
        let shape = NotchShape(radius: model.expanded ? 26 : (timer.isLive ? 12 : 8))
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                shape.fill(Color.black)
                if model.expanded {
                    ExpandedView(model: model, system: model.system, timer: timer)
                        .transition(.opacity)
                } else if timer.isLive {
                    LiveTimerView(timer: timer, notchWidth: model.notchSize.width)
                        .frame(height: model.notchSize.height)
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(shape)
            .shadow(color: .black.opacity(model.expanded ? 0.45 : 0), radius: 12, y: 4)
            Spacer(minLength: 0)
        }
        .frame(width: Layout.windowSize.width, height: Layout.windowSize.height, alignment: .top)
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: model.expanded)
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: timer.isLive)
        .contextMenu {
            Button(LaunchAtLogin.isEnabled ? "✓ Запускать при входе" : "Запускать при входе") { LaunchAtLogin.toggle() }
            Divider()
            Button("Выйти из Chelka") { NSApp.terminate(nil) }
        }
    }
}

/// Отсчёт таймера по бокам от камеры, когда панель свёрнута.
struct LiveTimerView: View {
    @ObservedObject var timer: FocusTimer
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: timer.justFinished ? "checkmark.circle.fill" : (timer.isPaused ? "pause.fill" : "timer"))
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: notchWidth)
            Text(timer.justFinished ? "Готово" : Format.countdown(timer.remaining))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(timer.justFinished ? Color.green : (timer.isPaused ? Color.white.opacity(0.6) : Color.orange))
        .padding(.horizontal, 14)
    }
}

struct ExpandedView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var system: SystemFeed
    @ObservedObject var timer: FocusTimer

    var body: some View {
        VStack(spacing: 12) {
            // Верхняя строка по бокам от камеры: слева время и дата, справа заряд, громкость, яркость.
            HStack(spacing: 0) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(Format.clock(context.date))
                            .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        Text(Format.shortDate(context.date))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                Spacer(minLength: model.notchSize.width + 24)
                HStack(spacing: 12) {
                    if let battery = system.battery {
                        Indicator(symbol: system.charging ? "battery.100.bolt" : Format.batterySymbol(battery),
                                  text: "\(battery)%",
                                  tint: battery <= 20 && !system.charging ? .red : nil)
                    }
                    if let volume = system.volume {
                        Indicator(symbol: Format.volumeSymbol(volume, muted: system.muted),
                                  text: system.muted ? "выкл" : Format.percent(Double(volume)))
                    }
                    if let brightness = system.brightness {
                        Indicator(symbol: "sun.max.fill", text: Format.percent(Double(brightness)))
                    }
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .frame(height: max(model.notchSize.height - 4, 18))

            HStack(alignment: .top, spacing: 18) {
                SystemSection(system: system)
                    .frame(width: 210, alignment: .leading)
                SectionDivider()
                ControlsSection(system: system)
                    .frame(width: 180, alignment: .leading)
                SectionDivider()
                TimerSection(timer: timer)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.top, 2)
        .padding(.bottom, 18)
        .frame(width: Layout.expandedSize.width, height: Layout.expandedSize.height, alignment: .top)
    }
}

// MARK: - Колонки

struct SystemSection: View {
    @ObservedObject var system: SystemFeed

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionTitle("СИСТЕМА")
            StatRow(symbol: "cpu", title: "Процессор",
                    value: system.cpu.map(Format.percent) ?? "—",
                    fraction: system.cpu, tint: Format.loadColor(system.cpu ?? 0))
            StatRow(symbol: "memorychip", title: "Память",
                    value: "\(Format.gigabytes(system.memoryUsed, decimals: 1)) / \(Format.gigabytes(system.memoryTotal, decimals: 0))",
                    fraction: system.memoryUsed / max(system.memoryTotal, 1),
                    tint: Format.memoryColor(freePercent: system.memoryFreePercent))
            StatRow(symbol: "internaldrive", title: "Диск",
                    value: system.diskFree.map { "своб. \(Format.gigabytes($0, decimals: 0, binary: false))" } ?? "—",
                    fraction: diskFraction, tint: Format.loadColor(diskFraction ?? 0))
            HStack(spacing: 6) {
                Image(systemName: "network")
                    .frame(width: 16)
                    .foregroundStyle(.white.opacity(0.6))
                Text("↓ \(system.download.map(Format.speed) ?? "—")")
                Spacer(minLength: 4)
                Text("↑ \(system.upload.map(Format.speed) ?? "—")")
            }
            .font(.system(size: 11).monospacedDigit())
        }
    }

    private var diskFraction: Double? {
        guard let free = system.diskFree, let total = system.diskTotal, total > 0 else { return nil }
        return 1 - free / total
    }
}

struct ControlsSection: View {
    @ObservedObject var system: SystemFeed

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionTitle("УПРАВЛЕНИЕ")
            HStack(spacing: 8) {
                Button { system.toggleMute() } label: {
                    Image(systemName: Format.volumeSymbol(system.volume ?? 0, muted: system.muted))
                        .frame(width: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                ThinSlider(value: system.muted ? 0 : Double(system.volume ?? 0)) { system.setVolume(Float($0)) }
            }
            .disabled(system.volume == nil)
            .opacity(system.volume == nil ? 0.4 : 1)

            HStack(spacing: 8) {
                Image(systemName: "sun.max.fill")
                    .frame(width: 18)
                ThinSlider(value: Double(system.brightness ?? 0)) { system.setBrightness(Float($0)) }
            }
            .disabled(system.brightness == nil)
            .opacity(system.brightness == nil ? 0.4 : 1)

            HStack(spacing: 26) {
                MediaButton(symbol: "backward.fill") { MediaKeys.press(MediaKeys.previous) }
                MediaButton(symbol: "playpause.fill", size: 17) { MediaKeys.press(MediaKeys.playPause) }
                MediaButton(symbol: "forward.fill") { MediaKeys.press(MediaKeys.next) }
            }
            .frame(maxWidth: .infinity)
        }
        .font(.system(size: 12))
    }
}

/// Тонкий ползунок в стиле панели: тянешь или кликаешь в нужное место.
struct ThinSlider: View {
    let value: Double
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(6, width * CGFloat(min(max(value, 0), 1))))
            }
            .frame(height: 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in onChange(Double(min(max(drag.location.x / width, 0), 1))) }
            )
        }
        .frame(height: 18)
    }
}

struct TimerSection: View {
    @ObservedObject var timer: FocusTimer
    @State private var dragStartMinutes: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                SectionTitle("ТАЙМЕР")
                Spacer()
                if timer.justFinished {
                    Text("Готово!")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                }
            }
            if timer.isActive {
                running
            } else {
                setup
            }
        }
    }

    /// Таймер идёт или на паузе.
    @ViewBuilder private var running: some View {
        Text(Format.countdown(timer.remaining))
            .font(.system(size: 28, weight: .semibold).monospacedDigit())
            .foregroundStyle(timer.isPaused ? Color.white.opacity(0.5) : Color.orange)
            .frame(height: 36)
        HStack(spacing: 5) {
            Chip(timer.isPaused ? "Дальше" : "Пауза") { timer.togglePause() }
            Chip("+5") { timer.add(minutes: 5) }
            Chip("Стоп") { timer.stop() }
        }
    }

    /// Выбор времени: − и +, перетаскивание по числу, быстрые варианты, «Старт».
    @ViewBuilder private var setup: some View {
        HStack(spacing: 8) {
            RoundButton(symbol: "minus") { timer.adjustDraft(by: -1) }
            Text(Format.countdown(TimeInterval(timer.draftMinutes * 60)))
                .font(.system(size: 26, weight: .semibold).monospacedDigit())
                .frame(minWidth: 84)
                .contentShape(Rectangle())
                .gesture(
                    // Тянешь вверх или вправо — больше, вниз или влево — меньше.
                    DragGesture(minimumDistance: 2)
                        .onChanged { drag in
                            let start = dragStartMinutes ?? timer.draftMinutes
                            dragStartMinutes = start
                            let steps = Int((drag.translation.width - drag.translation.height) / 6)
                            timer.draftMinutes = start + steps
                        }
                        .onEnded { _ in dragStartMinutes = nil }
                )
            RoundButton(symbol: "plus") { timer.adjustDraft(by: 1) }
        }
        .frame(height: 36)
        HStack(spacing: 5) {
            ForEach([5, 15, 30, 60], id: \.self) { minutes in
                Chip(minutes == 60 ? "1 ч" : "\(minutes)", selected: timer.draftMinutes == minutes) {
                    timer.draftMinutes = minutes
                }
            }
        }
        Button { timer.start() } label: {
            HStack(spacing: 5) {
                Image(systemName: "play.fill")
                Text("Старт")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.orange))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct RoundButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.13)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Мелкие элементы

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.45))
    }
}

struct SectionDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1)
    }
}

struct Indicator: View {
    let symbol: String
    let text: String
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .foregroundStyle(tint ?? Color.white.opacity(0.75))
            Text(text).monospacedDigit()
        }
    }
}

struct StatRow: View {
    let symbol: String
    let title: String
    let value: String
    let fraction: Double?
    let tint: Color

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .frame(width: 16)
                    .foregroundStyle(.white.opacity(0.6))
                Text(title)
                    .foregroundStyle(.white.opacity(0.75))
                Spacer(minLength: 4)
                Text(value).monospacedDigit()
            }
            .font(.system(size: 11))
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * CGFloat(min(max(fraction ?? 0, 0), 1)))
                }
            }
            .frame(height: 3)
            .padding(.leading, 22)
        }
    }
}

struct MediaButton: View {
    let symbol: String
    var size: CGFloat = 14
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    init(_ title: String, selected: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.selected = selected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? Color.black : Color.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(selected ? Color.white : Color.white.opacity(0.13)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Форматирование

enum Format {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = format
        return f
    }

    private static let clockFormatter = formatter("HH:mm")
    private static let dateFormatter = formatter("EE, d MMMM")

    static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }

    static func shortDate(_ date: Date) -> String {
        let text = dateFormatter.string(from: date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    static func countdown(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// binary: память считаем в ГиБ (как macOS для ОЗУ), диск — в десятичных ГБ (как Finder).
    static func gigabytes(_ bytes: Double, decimals: Int, binary: Bool = true) -> String {
        let value = bytes / (binary ? 1_073_741_824 : 1_000_000_000)
        let text = String(format: "%.\(decimals)f", value).replacingOccurrences(of: ".", with: ",")
        return "\(text) ГБ"
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        switch bytesPerSecond {
        case 1_000_000...:
            return String(format: "%.1f МБ/с", bytesPerSecond / 1_000_000).replacingOccurrences(of: ".", with: ",")
        case 1_000...:
            return "\(Int(bytesPerSecond / 1_000)) КБ/с"
        default:
            return "\(Int(bytesPerSecond)) Б/с"
        }
    }

    static func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case 88...: return "battery.100"
        case 63..<88: return "battery.75"
        case 38..<63: return "battery.50"
        case 13..<38: return "battery.25"
        default: return "battery.0"
        }
    }

    static func volumeSymbol(_ volume: Float, muted: Bool) -> String {
        if muted || volume <= 0 { return "speaker.slash.fill" }
        switch volume {
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    static func loadColor(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.6: return .green
        case ..<0.85: return .yellow
        default: return .red
        }
    }

    /// Цвет по оценке системы: важна не занятая память (macOS занимает почти всю), а сколько её реально свободно.
    static func memoryColor(freePercent: Int?) -> Color {
        guard let free = freePercent else { return .green }
        switch free {
        case 30...: return .green
        case 15..<30: return .yellow
        default: return .red
        }
    }
}
