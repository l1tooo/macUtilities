import AppKit
import SwiftUI

/// Рисует панель с примерными данными в PNG (режим `--snapshot`):
/// пустой калькулятор в `файл.png`, калькулятор с примером в `файл-calc.png`.
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
        return write(NotchRoot(model: model), to: base + "-calc.png")
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
