import SwiftUI

/// Keep the reading surfaces dark enough for subtitles while letting the
/// terrain continue behind them. Increased contrast uses a stronger backing.
struct StudioGlass: ViewModifier {
    var radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content.background {
            if reduceTransparency {
                shape.fill(Color(red: 0.07, green: 0.10, blue: 0.14))
            } else {
                backdrop(shape)
                shape.fill(Color(red: 0.012, green: 0.032, blue: 0.056)
                    .opacity(contrast == .increased ? 0.90 : 0.55))
                shape.fill(LinearGradient(colors: [.white.opacity(0.10), .clear, .cyan.opacity(0.045)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }.overlay {
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.06),
                                                      .cyan.opacity(0.19)], startPoint: .topLeading,
                                              endPoint: .bottomTrailing), lineWidth: 0.8)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private func backdrop(_ shape: RoundedRectangle) -> some View {
        // The local macOS 15 build and the Xcode project share this source.
        #if canImport(SwiftUI, _version: 7.0)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(.ultraThinMaterial).opacity(0.50)
        }
        #else
        shape.fill(.ultraThinMaterial).opacity(0.50)
        #endif
    }
}
