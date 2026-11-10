import Foundation
import Combine

/// Простой калькулятор как в macOS: число, действие, число, «=».
/// Считает в Decimal, поэтому 0,1 + 0,2 = 0,3, а не 0,30000000000000004.
final class Calculator: ObservableObject {
    enum Op: String {
        case add = "+", subtract = "−", multiply = "×", divide = "÷"
    }

    /// Число, которое сейчас набирается или показывается (без пробелов между разрядами, с запятой).
    @Published private(set) var entry = "0"
    /// Первое число и действие, которые ждут второго числа.
    @Published private(set) var accumulator: Decimal?
    @Published private(set) var pendingOp: Op?
    @Published private(set) var isError = false

    /// Следующая цифра начинает новое число (после действия, «=» или %).
    private var startNew = true
    /// В entry лежит введённое пользователем число (а не результат прошлого шага, к которому ещё ничего не добавили).
    private var hasEntry = false

    static let maxDigits = 12

    // MARK: Ввод

    func digit(_ d: Int) {
        guard (0...9).contains(d) else { return }
        if isError { clear() }
        if startNew {
            entry = "0"
            startNew = false
        }
        if entry == "0" {
            entry = String(d)
        } else if entry == "-0" {
            entry = "-" + String(d)
        } else if entry.filter(\.isNumber).count < Self.maxDigits {
            entry += String(d)
        }
        hasEntry = true
    }

    func comma() {
        if isError { clear() }
        if startNew {
            entry = "0"
            startNew = false
        }
        if !entry.contains(",") { entry += "," }
        hasEntry = true
    }

    func backspace() {
        guard !isError, !startNew else { return }
        entry.removeLast()
        if entry.isEmpty || entry == "-" { entry = "0" }
    }

    func toggleSign() {
        guard !isError else { return }
        if entry.hasPrefix("-") {
            entry.removeFirst()
        } else if entry != "0" {
            entry = "-" + entry
        }
        hasEntry = true
    }

    /// 50 + 10% = 55 (процент от первого числа); без действия — просто деление на 100.
    func percent() {
        guard !isError else { return }
        let value = currentValue
        let result: Decimal
        if let acc = accumulator, pendingOp == .add || pendingOp == .subtract {
            result = acc * value / 100
        } else {
            result = value / 100
        }
        show(result)
        hasEntry = true
    }

    func operation(_ op: Op) {
        guard !isError else { return }
        if let acc = accumulator, let pending = pendingOp, hasEntry {
            guard let result = Self.apply(pending, acc, currentValue) else { return fail() }
            accumulator = result
            show(result)
        } else if accumulator == nil || hasEntry {
            accumulator = currentValue
        }
        // Второе действие подряд просто заменяет первое.
        pendingOp = op
        startNew = true
        hasEntry = false
    }

    func equals() {
        guard !isError, let acc = accumulator, let pending = pendingOp else { return }
        // «5 × =» считает 5 × 5, как в калькуляторе macOS.
        let second = hasEntry ? currentValue : acc
        guard let result = Self.apply(pending, acc, second) else { return fail() }
        accumulator = nil
        pendingOp = nil
        show(result)
        hasEntry = true
    }

    func clear() {
        entry = "0"
        accumulator = nil
        pendingOp = nil
        isError = false
        startNew = true
        hasEntry = false
    }

    // MARK: Показ

    var currentValue: Decimal {
        Decimal(string: entry.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }

    /// Большая строка: «1 234,5». Пробелы между разрядами — неразрывные узкие.
    var display: String {
        isError ? "Ошибка" : Self.grouped(entry)
    }

    /// Мелкая строка над числом: «1 250 ×».
    var expression: String {
        guard let acc = accumulator, let op = pendingOp, !isError else { return "" }
        return "\(Self.grouped(Self.format(acc))) \(op.rawValue)"
    }

    /// Что копировать в буфер: число без пробелов, с запятой.
    var copyText: String { isError ? "" : entry }

    /// Для картинки в README: «1 250 × 12».
    func setPreview(accumulator: Decimal, op: Op, entry: String) {
        clear()
        self.accumulator = accumulator
        pendingOp = op
        self.entry = entry
        startNew = false
        hasEntry = true
    }

    // MARK: Внутреннее

    private func show(_ value: Decimal) {
        entry = Self.format(value)
        startNew = true
    }

    private func fail() {
        clear()
        isError = true
    }

    static func apply(_ op: Op, _ a: Decimal, _ b: Decimal) -> Decimal? {
        switch op {
        case .add: return a + b
        case .subtract: return a - b
        case .multiply: return a * b
        case .divide: return b == 0 ? nil : a / b
        }
    }

    /// Округляем до 10 знаков после запятой; очень большие и очень маленькие числа — в виде 1,2e15.
    static func format(_ value: Decimal) -> String {
        let magnitude = abs(value)
        if magnitude >= 1e12 || (magnitude > 0 && magnitude < 1e-9) {
            // %g даёт «9.99898e+15»; приводим к «9,99898e15».
            let text = String(format: "%.8g", NSDecimalNumber(decimal: value).doubleValue)
            let parts = text.split(separator: "e")
            guard parts.count == 2, let exponent = Int(parts[1]) else { return text }
            return parts[0].replacingOccurrences(of: ".", with: ",") + "e\(exponent)"
        }
        var source = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 10, .plain)
        let text = NSDecimalNumber(decimal: rounded).stringValue
        return text == "-0" ? "0" : text.replacingOccurrences(of: ".", with: ",")
    }

    /// Разбивка целой части на группы по три цифры.
    static func grouped(_ text: String) -> String {
        guard !text.contains("e") else { return text }
        let negative = text.hasPrefix("-")
        let body = negative ? String(text.dropFirst()) : text
        let parts = body.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        let integer = Array(parts[0])
        var result = ""
        for (index, char) in integer.enumerated() {
            if index > 0, (integer.count - index) % 3 == 0 { result.append("\u{202F}") }
            result.append(char)
        }
        if parts.count > 1 { result += "," + parts[1] }
        return (negative ? "-" : "") + result
    }
}
