import AppKit
import AudioToolbox
import CoreAudio
import Darwin
import IOKit.ps

// MARK: - Сводка по системе

/// Процессор, память, диск, сеть, батарея, громкость, яркость и заряд Bluetooth-устройств.
/// Обновляется раз в секунду (Bluetooth — раз в 30 секунд) и только пока панель раскрыта.
final class SystemFeed: ObservableObject {
    @Published private(set) var cpu: Double?
    @Published private(set) var memoryUsed: Double = 0
    @Published private(set) var memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)
    /// Свободная память в процентах по оценке системы (как `memory_pressure`).
    @Published private(set) var memoryFreePercent: Int?
    @Published private(set) var diskFree: Double?
    @Published private(set) var diskTotal: Double?
    @Published private(set) var download: Double?
    @Published private(set) var upload: Double?
    @Published private(set) var battery: Int?
    @Published private(set) var charging = false
    @Published private(set) var volume: Float?
    @Published private(set) var muted = false
    @Published private(set) var brightness: Float?
    /// Подключённые Bluetooth-устройства с зарядом. Прошлый список не стираем при закрытии панели,
    /// чтобы при раскрытии она сразу была нужной высоты.
    @Published private(set) var bluetooth: [BluetoothDevice] = []

    var active = false {
        didSet {
            guard active, !oldValue else { return }
            // Сбрасываем прошлые замеры: иначе первая цифра будет средним за всё время, пока панель была закрыта.
            lastTicks = nil
            lastNet = nil
            cpu = nil
            download = nil
            upload = nil
            bluetoothCheckedAt = nil
            refresh()
        }
    }

    private let host = mach_host_self()
    private var timer: Timer?
    private var lastTicks: [UInt32]?
    private var lastNet: (bytesIn: UInt64, bytesOut: UInt64, time: Date)?
    private var diskCheckedAt: Date?
    private var bluetoothCheckedAt: Date?
    private var bluetoothBusy = false

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.active else { return }
            self.refresh()
        }
    }

    func refresh() {
        sampleCPU()
        sampleMemory()
        sampleDisk()
        sampleNetwork()
        sampleBattery()
        volume = SystemAudio.volume()
        muted = SystemAudio.isMuted()
        brightness = DisplayBrightness.get()
        sampleBluetooth()
    }

    /// Для режима `--probe`: прочитать Bluetooth сразу, на этом потоке.
    func refreshBluetoothNow() {
        bluetooth = BluetoothBatteries.read()
    }

    func setVolume(_ value: Float) {
        SystemAudio.setVolume(value)
        volume = SystemAudio.volume()
        muted = SystemAudio.isMuted()
    }

    func toggleMute() {
        SystemAudio.setMuted(!muted)
        muted = SystemAudio.isMuted()
    }

    func setBrightness(_ value: Float) {
        DisplayBrightness.set(value)
        brightness = DisplayBrightness.get()
    }

    // MARK: Замеры

    private func sampleCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        // Порядок: user, system, idle, nice.
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        defer { lastTicks = ticks }
        guard let last = lastTicks else { return }
        let delta = zip(ticks, last).map { Double($0 &- $1) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return }
        cpu = (delta[0] + delta[1] + delta[3]) / total
    }

    private func sampleBluetooth() {
        if let checked = bluetoothCheckedAt, Date().timeIntervalSince(checked) < 30 { return }
        guard !bluetoothBusy else { return }
        bluetoothCheckedAt = Date()
        bluetoothBusy = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let devices = BluetoothBatteries.read()
            DispatchQueue.main.async {
                guard let self else { return }
                self.bluetoothBusy = false
                if self.bluetooth != devices { self.bluetooth = devices }
            }
        }
    }

    private func sampleMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            // Так же считает «Мониторинг системы»: память приложений + неперемещаемая + сжатая.
            let page = Double(vm_kernel_page_size)
            let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
            memoryUsed = (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        }
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 {
            memoryFreePercent = Int(level)
        }
    }

    private func sampleDisk() {
        if let checked = diskCheckedAt, Date().timeIntervalSince(checked) < 15 { return }
        diskCheckedAt = Date()
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return }
        diskFree = values.volumeAvailableCapacityForImportantUsage.map(Double.init)
        diskTotal = values.volumeTotalCapacity.map(Double.init)
    }

    private func sampleNetwork() {
        let now = Date()
        let current = Self.networkBytes()
        defer { lastNet = (current.bytesIn, current.bytesOut, now) }
        guard let last = lastNet else { return }
        let seconds = now.timeIntervalSince(last.time)
        // Счётчик сбросился или переполнился — пропускаем этот замер.
        guard seconds > 0, current.bytesIn >= last.bytesIn, current.bytesOut >= last.bytesOut else { return }
        download = Double(current.bytesIn - last.bytesIn) / seconds
        upload = Double(current.bytesOut - last.bytesOut) / seconds
    }

    /// Только физические интерфейсы en* (Wi-Fi, кабель). VPN (utun) не считаем, иначе трафик удвоится.
    private static func networkBytes() -> (bytesIn: UInt64, bytesOut: UInt64) {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return (0, 0) }
        defer { freeifaddrs(list) }
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: entry.ifa_name).hasPrefix("en"),
                  let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            bytesIn += UInt64(data.pointee.ifi_ibytes)
            bytesOut += UInt64(data.pointee.ifi_obytes)
        }
        return (bytesIn, bytesOut)
    }

    private func sampleBattery() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            battery = nil
            return
        }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            battery = Int((Double(current) / Double(max) * 100).rounded())
            charging = (description[kIOPSIsChargingKey] as? Bool) ?? false
            return
        }
        battery = nil
    }

    // MARK: Пример для `--snapshot`

    func setPreview() {
        cpu = 0.14
        memoryUsed = 5.3 * 1_073_741_824
        memoryTotal = 8 * 1_073_741_824
        memoryFreePercent = 48
        diskFree = 780 * 1_000_000_000
        diskTotal = 994 * 1_000_000_000
        download = 1_250_000
        upload = 82_000
        battery = 87
        charging = false
        volume = 0.6
        muted = false
        brightness = 0.7
        bluetooth = [
            BluetoothDevice(name: "AirPods Pro", kind: .airpods, left: 80, right: 75, caseLevel: 40),
            BluetoothDevice(name: "Magic Keyboard", kind: .keyboard, main: 64),
            BluetoothDevice(name: "Magic Mouse", kind: .mouse, main: 15),
        ]
    }
}

// MARK: - Громкость (CoreAudio, без разрешений)

enum SystemAudio {
    private static func defaultOutput() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    /// nil — устройство не даёт менять громкость (например, HDMI).
    static func volume() -> Float? {
        guard let device = defaultOutput() else { return nil }
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func setVolume(_ value: Float) {
        guard let device = defaultOutput() else { return }
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var newValue = Float32(min(max(value, 0), 1))
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &newValue)
        if newValue > 0, isMuted() { setMuted(false) }
    }

    static func isMuted() -> Bool {
        guard let device = defaultOutput() else { return false }
        var address = address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    static func setMuted(_ muted: Bool) {
        guard let device = defaultOutput() else { return }
        var address = address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &address) else { return }
        var value = UInt32(muted ? 1 : 0)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

// MARK: - Яркость встроенного экрана

/// У Apple нет открытого способа менять яркость встроенного экрана, поэтому используем
/// системную библиотеку DisplayServices (её же вызывают «Пункт управления» и утилиты вроде MonitorControl).
/// Если её не окажется, ползунок просто будет неактивен.
enum DisplayBrightness {
    private typealias GetFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getFunction: GetFunction? = library
        .flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: GetFunction.self) }
    private static let setFunction: SetFunction? = library
        .flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: SetFunction.self) }

    private static var builtinDisplay: CGDirectDisplayID? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    static func get() -> Float? {
        guard let getFunction, let display = builtinDisplay else { return nil }
        var value: Float = 0
        return getFunction(display, &value) == 0 ? value : nil
    }

    static func set(_ value: Float) {
        guard let setFunction, let display = builtinDisplay else { return }
        _ = setFunction(display, min(max(value, 0), 1))
    }
}

// MARK: - Медиаклавиши (⏮ ⏯ ⏭ для музыки в браузере)

/// Отправляет системе нажатие медиаклавиши, как кнопки F7–F9.
/// Их получает тот, кто сейчас играет звук, в том числе вкладка браузера.
/// Чтобы отправлять нажатия, macOS требует «Универсальный доступ».
enum MediaKeys {
    static let playPause: Int32 = 16   // NX_KEYTYPE_PLAY
    static let next: Int32 = 17        // NX_KEYTYPE_NEXT
    static let previous: Int32 = 18    // NX_KEYTYPE_PREVIOUS

    static var isAllowed: Bool { AXIsProcessTrusted() }

    static func press(_ key: Int32) {
        guard ensureAllowed() else { return }
        for down in [true, false] {
            let state: Int32 = down ? 0xA : 0xB
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state) << 8),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: Int((key << 16) | (state << 8)),
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// При первом нажатии macOS покажет окно с просьбой дать доступ.
    private static func ensureAllowed() -> Bool {
        if AXIsProcessTrusted() { return true }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
