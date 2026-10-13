import SwiftUI

/// Cores e componentes no estilo escuro do FocuSee
enum Theme {
    static let bg = Color(red: 0.055, green: 0.059, blue: 0.071)
    static let panel = Color(red: 0.078, green: 0.082, blue: 0.098)
    static let field = Color.white.opacity(0.05)
    static let stroke = Color.white.opacity(0.12)
    static let text2 = Color.white.opacity(0.6)
    static let accent = Color(red: 0.24, green: 0.43, blue: 0.98)
    static let selected = Color(red: 0.07, green: 0.15, blue: 0.40)
    static let playhead = Color(red: 0.96, green: 0.65, blue: 0.23)
    static let gradient = LinearGradient(colors: [Color(red: 0.23, green: 0.47, blue: 1.0), Color(red: 0.62, green: 0.38, blue: 1.0)],
                                         startPoint: .leading, endPoint: .trailing)
    static let clip = LinearGradient(colors: [Color(red: 0.45, green: 0.22, blue: 0.88), Color(red: 0.30, green: 0.12, blue: 0.62)],
                                     startPoint: .top, endPoint: .bottom)
    static let zoom = LinearGradient(colors: [Color(red: 0.24, green: 0.43, blue: 0.98), Color(red: 0.42, green: 0.36, blue: 1.0)],
                                     startPoint: .leading, endPoint: .trailing)
}

extension RGBA {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    init(_ c: Color) {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .white
        self.init(r: n.redComponent, g: n.greenComponent, b: n.blueComponent, a: n.alphaComponent)
    }
}

struct GradientButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Caixa selecionável (chips, estilos, efeitos)
struct Tile<Content: View>: View {
    let selected: Bool
    var radius: CGFloat = 10
    let action: () -> Void
    @ViewBuilder let content: Content
    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(selected ? Theme.selected : Theme.field, in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).stroke(selected ? Theme.accent : Theme.stroke, lineWidth: selected ? 2 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var shown: (Double) -> String = { String(Int(($0 * 100).rounded())) }
    var reset: Double? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                if let reset, abs(value - reset) > 0.0001 {
                    Button("Redefinir") { value = reset }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                }
                Text(shown(value)).foregroundStyle(Theme.text2).monospacedDigit().frame(minWidth: 34, alignment: .trailing)
            }
            Slider(value: $value, in: range).tint(Theme.accent)
        }
        .font(.callout)
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.headline).foregroundStyle(.white.opacity(0.92)) }
}

/// Menu suspenso com cara de campo (como os do FocuSee)
struct FieldMenu<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    var body: some View {
        Menu { content } label: {
            HStack {
                Text(label).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down").font(.caption.bold()).foregroundStyle(Theme.text2)
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    }
}

extension View {
    func panelCard() -> some View {
        padding(14).background(Theme.field, in: RoundedRectangle(cornerRadius: 12))
    }
}
