import AppKit
import SwiftUI

/// Рисует панель с примерными данными в PNG (режим `--snapshot`):
/// пустой калькулятор в `файл.png`, калькулятор с примером в `файл-calc.png`,
/// идущая запись экрана в `файл-rec.png` и свёрнутая во время записи в `файл-rec-live.png`.
enum Snapshot {
    @MainActor
    static func render(to path: String) -> Bool {
        let model = NotchModel()
        model.notchSize = CGSize(width: 185, height: 32)
        model.system.setPreview()
        let base = (path as NSString).deletingPathExtension

        // 1. Раскрыта, калькулятор пустой.
        model.expanded = true
        guard write(NotchRoot(model: model), to: path) else { return false }

        // 2. Раскрыта, в калькуляторе пример с действием (подсвечено ×) и длинным числом.
        model.calculator.setPreview(accumulator: 1250, op: .multiply, entry: "12345,67")
        guard write(NotchRoot(model: model), to: base + "-calc.png") else { return false }

        // 3. Идёт запись экрана: в панели время и «Стоп», в свёрнутом виде — точка и время у выреза.
        model.recorder.setPreview(elapsed: 83)
        guard write(NotchRoot(model: model), to: base + "-rec.png") else { return false }
        model.expanded = false
        return write(NotchRoot(model: model), to: base + "-rec-live.png")
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
