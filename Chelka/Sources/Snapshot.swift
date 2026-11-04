import AppKit
import SwiftUI

/// Рисует панель с примерными данными в PNG (режим `--snapshot`):
/// раскрытую в `файл.png` и свёрнутую с идущим таймером в `файл-live.png`.
enum Snapshot {
    @MainActor
    static func render(to path: String) -> Bool {
        let model = NotchModel()
        model.notchSize = CGSize(width: 185, height: 32)
        model.system.setPreview()
        let base = (path as NSString).deletingPathExtension

        // 1. Раскрыта, таймер не запущен — выбор времени.
        model.expanded = true
        guard write(NotchRoot(model: model), to: path) else { return false }

        // 2. Раскрыта, таймер идёт.
        model.timer.setPreview(remaining: 754)
        guard write(NotchRoot(model: model), to: base + "-running.png") else { return false }

        // 3. Свёрнута, отсчёт по бокам от выреза.
        model.expanded = false
        return write(NotchRoot(model: model), to: base + "-live.png")
    }

    @MainActor
    private static func write(_ root: NotchRoot, to path: String) -> Bool {
        let renderer = ImageRenderer(content: root.background(Color(white: 0.78)))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            return false
        }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
