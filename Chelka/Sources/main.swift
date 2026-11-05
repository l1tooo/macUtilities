// Chelka — панель в вырезе экрана MacBook: при наведении раскрывается
// и показывает время, систему, громкость, яркость и таймер.

import AppKit
import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = NotchController()
        controller.start()
        self.controller = controller
        LaunchAtLogin.enableOnFirstLaunch()
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// При первом запуске сразу включаем автозапуск: иначе после перезагрузки панель пропадает,
    /// а пункт меню спрятан в правом клике. Если пользователь потом выключит его, больше не трогаем.
    static func enableOnFirstLaunch() {
        let key = "launchAtLoginOffered"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if !isEnabled { toggle() }
    }

    static func toggle() {
        do {
            if isEnabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            NSLog("Chelka: автозапуск не изменён: \(error.localizedDescription)")
        }
    }
}

// `Chelka --snapshot файл.png` — нарисовать раскрытую панель с примерными данными и выйти.
// Нужен, чтобы проверить вёрстку без разрешений и без записи экрана.
let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
    _ = NSApplication.shared
    let ok = MainActor.assumeIsolated { Snapshot.render(to: arguments[index + 1]) }
    exit(ok ? 0 : 1)
}

// `Chelka --promo файл.png` — красивая картинка для друзей.
if let index = arguments.firstIndex(of: "--promo"), index + 1 < arguments.count {
    _ = NSApplication.shared
    let ok = MainActor.assumeIsolated { Promo.render(to: arguments[index + 1]) }
    exit(ok ? 0 : 1)
}

// `Chelka --probe` — вывести настоящие показания системы в терминал и выйти (проверка датчиков).
if arguments.contains("--probe") {
    let feed = SystemFeed()
    feed.refresh()
    Thread.sleep(forTimeInterval: 1)
    feed.refresh()
    print("cpu=\(feed.cpu.map(Format.percent) ?? "nil") memory=\(Format.gigabytes(feed.memoryUsed, decimals: 1))/\(Format.gigabytes(feed.memoryTotal, decimals: 0)) free%=\(feed.memoryFreePercent.map(String.init) ?? "nil")")
    print("disk free=\(feed.diskFree.map { Format.gigabytes($0, decimals: 0, binary: false) } ?? "nil") net ↓\(feed.download.map(Format.speed) ?? "nil") ↑\(feed.upload.map(Format.speed) ?? "nil")")
    print("battery=\(feed.battery.map(String.init) ?? "nil") charging=\(feed.charging) volume=\(feed.volume.map { Format.percent(Double($0)) } ?? "nil") muted=\(feed.muted) brightness=\(feed.brightness.map { Format.percent(Double($0)) } ?? "nil")")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
