import SwiftUI

/// Scrolls its text horizontally when it doesn't fit the available width,
/// matching the "now playing" title treatment seen in system media surfaces.
/// Sits still (no measurement flicker) when the text already fits.
struct MarqueeText: View {
    let text: String
    var font: Font
    var color: Color

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var animate = false

    private var needsScroll: Bool { textWidth > containerWidth + 1 }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if needsScroll {
                    HStack(spacing: 28) {
                        label
                        label
                    }
                    .offset(x: animate ? -(textWidth + 28) : 0)
                    .animation(
                        .linear(duration: max(3, Double(textWidth) / 28))
                            .repeatForever(autoreverses: false)
                            .delay(1.2),
                        value: animate
                    )
                    .onAppear { animate = true }
                    .onDisappear { animate = false }
                } else {
                    label
                }
            }
            .onAppear { containerWidth = geo.size.width }
            .onChange(of: geo.size.width) { containerWidth = $0 }
        }
        .frame(height: fontLineHeight)
        .clipped()
        .mask(
            needsScroll
                ? AnyView(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.92),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                : AnyView(Color.black)
        )
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .fixedSize()
            .lineLimit(1)
            .background(
                GeometryReader { textGeo in
                    Color.clear.onAppear { textWidth = textGeo.size.width }
                }
            )
    }

    private var fontLineHeight: CGFloat { 17 }
}
