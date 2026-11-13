import Foundation
import IOKit

/// Подключённое Bluetooth-устройство с зарядом.
struct BluetoothDevice: Identifiable, Equatable {
    enum Kind { case mouse, keyboard, trackpad, airpods, headphones, speaker, gamepad, other }

    let name: String
    let kind: Kind
    /// Один аккумулятор (мышь, клавиатура, обычные наушники).
    var main: Int?
    /// AirPods и похожие: левый, правый наушник и футляр.
    var left: Int?
    var right: Int?
    var caseLevel: Int?

    var id: String { name }

    /// Самый низкий заряд — по нему решаем, подсвечивать ли красным.
    var lowest: Int? { [main, left, right].compactMap { $0 }.min() }
}

/// Заряд Bluetooth-устройств. Разрешения не нужны.
/// - Мышь, клавиатура и трекпад Apple: реестр IOKit (`AppleDeviceManagementHIDEventService`, ключ `BatteryPercent`).
/// - AirPods, Beats и наушники, которые сообщают заряд: `system_profiler SPBluetoothDataType -json`.
enum BluetoothBatteries {
    /// Вызывать не на главном потоке: system_profiler занимает около 0,1–0,5 с.
    static func read() -> [BluetoothDevice] {
        var devices = hidDevices()
        for device in profilerDevices() where !devices.contains(where: { $0.name == device.name }) {
            devices.append(device)
        }
        return devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Мышь, клавиатура, трекпад

    private static func hidDevices() -> [BluetoothDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [BluetoothDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let percent = property(service, "BatteryPercent") as? Int,
                  let name = property(service, "Product") as? String else { continue }
            result.append(BluetoothDevice(name: name, kind: kind(fromName: name), main: percent))
        }
        return result
    }

    private static func property(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    // MARK: Наушники

    private static func profilerDevices() -> [BluetoothDevice] {
        guard let data = run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: 5),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var result: [BluetoothDevice] = []
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    let device = BluetoothDevice(
                        name: name,
                        kind: kind(minorType: info["device_minorType"] as? String, name: name,
                                   hasPair: info["device_batteryLevelLeft"] != nil || info["device_batteryLevelRight"] != nil),
                        main: level(info["device_batteryLevelMain"]),
                        left: level(info["device_batteryLevelLeft"]),
                        right: level(info["device_batteryLevelRight"]),
                        caseLevel: level(info["device_batteryLevelCase"])
                    )
                    if device.main != nil || device.left != nil || device.right != nil || device.caseLevel != nil {
                        result.append(device)
                    }
                }
            }
        }
        return result
    }

    /// «80%» → 80.
    private static func level(_ value: Any?) -> Int? {
        guard let text = value as? String else { return value as? Int }
        return Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
    }

    static func kind(minorType: String?, name: String, hasPair: Bool) -> BluetoothDevice.Kind {
        if hasPair { return .airpods }
        switch minorType?.lowercased() ?? "" {
        case "mouse": return .mouse
        case "keyboard": return .keyboard
        case "trackpad": return .trackpad
        case "headphones", "headset", "hi-fi stereo", "portable audio": return .headphones
        case "speaker", "loudspeaker": return .speaker
        case "gamepad", "joystick": return .gamepad
        default: return kind(fromName: name)
        }
    }

    static func kind(fromName name: String) -> BluetoothDevice.Kind {
        let lower = name.lowercased()
        if lower.contains("airpods") { return .airpods }
        if lower.contains("mouse") || lower.contains("мышь") { return .mouse }
        if lower.contains("trackpad") { return .trackpad }
        if lower.contains("keyboard") || lower.contains("клавиатура") { return .keyboard }
        if lower.contains("controller") || lower.contains("gamepad") { return .gamepad }
        if lower.contains("buds") || lower.contains("beats") || lower.contains("headphone") { return .headphones }
        return .other
    }

    /// Запуск программы с ограничением по времени: зависший system_profiler не должен держать панель.
    private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return process.terminationStatus == 0 ? data : nil
    }
}
