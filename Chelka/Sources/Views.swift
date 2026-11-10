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

    private var size: CGSize {
        model.expanded ? Layout.expandedSize : Layout.collapsedSize(notch: model.notchSize)
    }

    var body: some View {
        let shape = NotchShape(radius: model.expanded ? 26 : 8)
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                shape.fill(Color.black)
                if model.expanded {
                    ExpandedView(model: model, system: model.system, calculator: model.calculator)
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
        .contextMenu {
            Button(LaunchAtLogin.isEnabled ? "✓ Запускать при входе" : "Запускать при входе") { LaunchAtLogin.toggle() }
            Divider()
            Button("Выйти из Chelka") { NSApp.terminate(nil) }
        }
    }
}

struct ExpandedView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var system: SystemFeed
    let calculator: Calculator

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
                    .frame(width: 196, alignment: .leading)
                SectionDivider()
                ControlsSection(system: system)
                    .frame(width: 168, alignment: .leading)
                SectionDivider()
                CalculatorSection(calculator: calculator)
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

/// Калькулятор: сверху мелко первое число и действие, ниже крупно текущее число.
/// Клик по числу копирует его в буфер обмена.
struct CalculatorSection: View {
    @ObservedObject var calculator: Calculator
    @State private var copied = false

    private enum Key: Hashable {
        case digit(Int), op(Calculator.Op), comma, equals, clear, backspace, percent, sign
    }

    private let rows: [[Key]] = [
        [.digit(7), .digit(8), .digit(9), .op(.divide), .clear],
        [.digit(4), .digit(5), .digit(6), .op(.multiply), .backspace],
        [.digit(1), .digit(2), .digit(3), .op(.subtract), .percent],
        [.sign, .digit(0), .comma, .op(.add), .equals],
    ]

    var body: some View {
        VStack(spacing: 4) {
            Button(action: copy) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(copied ? "скопировано" : (calculator.expression.isEmpty ? " " : calculator.expression))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(copied ? Color.green : Color.white.opacity(0.45))
                        .lineLimit(1)
                    Text(calculator.display)
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                        .foregroundStyle(calculator.isError ? Color.red : Color.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.45)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Скопировать число")

            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(rows[row], id: \.self) { key in
                            CalcKey(title: title(key), symbol: symbol(key), style: style(key)) { press(key) }
                        }
                    }
                }
            }
        }
    }

    private func press(_ key: Key) {
        copied = false
        switch key {
        case .digit(let d): calculator.digit(d)
        case .op(let op): calculator.operation(op)
        case .comma: calculator.comma()
        case .equals: calculator.equals()
        case .clear: calculator.clear()
        case .backspace: calculator.backspace()
        case .percent: calculator.percent()
        case .sign: calculator.toggleSign()
        }
    }

    private func copy() {
        guard !calculator.copyText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(calculator.copyText, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    private func title(_ key: Key) -> String {
        switch key {
        case .digit(let d): return String(d)
        case .op(let op): return op.rawValue
        case .comma: return ","
        case .equals: return "="
        case .clear: return "C"
        case .percent: return "%"
        case .sign: return "±"
        case .backspace: return ""
        }
    }

    private func symbol(_ key: Key) -> String? {
        key == .backspace ? "delete.left" : nil
    }

    private func style(_ key: Key) -> CalcKey.Style {
        switch key {
        case .digit, .comma, .sign: return .digit
        case .op(let op): return calculator.pendingOp == op && !calculator.isError ? .selected : .operation
        case .equals: return .operation
        case .clear, .backspace, .percent: return .function
        }
    }
}

struct CalcKey: View {
    enum Style { case digit, function, operation, selected }

    let title: String
    let symbol: String?
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                } else {
                    Text(title).font(.system(size: 13, weight: style == .digit ? .regular : .semibold))
                }
            }
            .foregroundStyle(style == .selected ? Color.orange : Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(background))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var background: Color {
        switch style {
        case .digit: return Color.white.opacity(0.13)
        case .function: return Color.white.opacity(0.24)
        case .operation: return Color.orange
        case .selected: return Color.white
        }
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
