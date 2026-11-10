import AppKit
import SwiftUI

/// Красивая картинка для друзей (режим `--promo файл.png`): «экран» MacBook с обоями,
/// строкой меню и раскрытой Chelka. Данные примерные, личного ничего нет.
enum Promo {
    static let canvas = CGSize(width: 1600, height: 1000)

    @MainActor
    static func render(to path: String) -> Bool {
        let model = NotchModel()
        model.notchSize = CGSize(width: 185, height: 32)
        model.system.setPreview()
        model.calculator.setPreview(accumulator: 1250, op: .multiply, entry: "12")
        model.expanded = true

        let renderer = ImageRenderer(content: PromoView(model: model))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            return false
        }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}

struct PromoView: View {
    let model: NotchModel
    private let now = Date()

    var body: some View {
        ZStack {
            // Фон вокруг «ноутбука».
            LinearGradient(colors: [Color(red: 0.93, green: 0.94, blue: 0.97), Color(red: 0.82, green: 0.85, blue: 0.92)],
                           startPoint: .top, endPoint: .bottom)

            VStack(spacing: 34) {
                screen
                caption
            }
        }
        .frame(width: Promo.canvas.width, height: Promo.canvas.height)
        .environment(\.colorScheme, .dark)
    }

    /// Экран с чёрной рамкой, как у MacBook.
    private var screen: some View {
        ZStack(alignment: .top) {
            wallpaper
            menuBar
            NotchRoot(model: model)
        }
        .frame(width: 1320, height: 680)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 34, style: .continuous).fill(Color.black))
        .shadow(color: .black.opacity(0.28), radius: 40, y: 22)
        .padding(.top, 60)
    }

    /// Обои в духе macOS: тёмно-синий градиент с мягкими цветными пятнами.
    private var wallpaper: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.08, blue: 0.22), Color(red: 0.16, green: 0.10, blue: 0.35)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            blob(color: Color(red: 0.25, green: 0.45, blue: 1.0), size: 760, x: -380, y: 260)
            blob(color: Color(red: 0.85, green: 0.30, blue: 0.75), size: 680, x: 420, y: 330)
            blob(color: Color(red: 1.0, green: 0.55, blue: 0.25), size: 420, x: 120, y: 520)
        }
        // Пятна больше экрана: без этой рамки они раздувают высоту и срезают верх.
        .frame(width: 1320, height: 680)
        .clipped()
    }

    private func blob(color: Color, size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(0.75), color.opacity(0)], center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
            .offset(x: x, y: y)
    }

    private var menuBar: some View {
        HStack(spacing: 20) {
            Image(systemName: "applelogo")
                .font(.system(size: 14, weight: .semibold))
            Text("Finder").fontWeight(.bold)
            ForEach(["Файл", "Правка", "Вид", "Переход", "Окно"], id: \.self) { Text($0) }
            Spacer()
            Image(systemName: "wifi")
            Image(systemName: "battery.75")
            Image(systemName: "magnifyingglass")
            Text("\(Format.shortDate(now))  \(Format.clock(now))")
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(height: 32)
        .background(Color.black.opacity(0.18))
    }

    private var caption: some View {
        VStack(spacing: 8) {
            Text("Chelka")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.10, green: 0.11, blue: 0.16))
            Text("Своя «чёлка» для MacBook: система, громкость, яркость и калькулятор прямо в вырезе экрана")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color(red: 0.30, green: 0.32, blue: 0.40))
        }
    }
}
