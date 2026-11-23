import SwiftUI
import QuartzCore
import ImageIO

struct StudioLunarScene: View {
    enum Kind { case home, workspace, question }
    let kind: Kind
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        LunarSurface(kind: kind, still: still)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct LunarSurface: NSViewRepresentable {
    let kind: StudioLunarScene.Kind
    let still: Bool

    func makeNSView(context: Context) -> LunarView { LunarView(frame: .zero) }

    func updateNSView(_ view: LunarView, context: Context) {
        view.configure(kind: kind, still: still)
    }

    final class LunarView: NSView {
        private static let framesPerSecond = 30.0
        private static let start = CACurrentMediaTime()
        private static let renderer = Bundle.main.url(forResource: "Earth", withExtension: "jpg", subdirectory: "LunarAssets")
            .flatMap { StudioLunarRenderer(earthURL: $0) }
        private static let landscape = Bundle.main.url(forResource: "LunarHorizon", withExtension: "jpg", subdirectory: "LunarAssets")
            .flatMap { CGImageSourceCreateWithURL($0 as CFURL,nil) }
            .flatMap { CGImageSourceCreateImageAtIndex($0,0,nil) }
        private let terrain = CALayer()
        private let earth = CALayer()
        private var timer: Timer?
        private var kind = StudioLunarScene.Kind.home
        private var still = false
        private var lastRenderTime: TimeInterval?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            terrain.contents = Self.landscape
            terrain.contentsGravity = .resizeAspectFill
            terrain.masksToBounds = true
            layer?.addSublayer(terrain)
            layer?.masksToBounds = true
            layer?.addSublayer(earth)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func configure(kind: StudioLunarScene.Kind, still: Bool) {
            guard self.kind != kind || self.still != still else { return }
            self.kind = kind
            self.still = still
            updateClock()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(updateClock),
                    name: NSWindow.didChangeOcclusionStateNotification, object: window)
            }
            updateClock()
        }

        @objc private func updateClock() {
            timer?.invalidate()
            timer = nil
            guard window?.occlusionState.contains(.visible) == true else { return }
            drawGlobe()
            if !still {
                let clock = Timer(timeInterval: 1 / Self.framesPerSecond, repeats: true) { [weak self] _ in self?.drawGlobe() }
                RunLoop.main.add(clock, forMode: .common)
                timer = clock
            }
        }
        override func layout() {
            super.layout()
            if bounds.width > 0 && bounds.height > 0 { drawGlobe() }
        }

        private func drawGlobe() {
            let time = still ? 0 : CACurrentMediaTime() - Self.start
            let light = StudioLunarLight(time: time)
            let workspace = kind == .workspace
            let size = min(bounds.height * (workspace ? 0.20 : 0.24), bounds.width * 0.23)
            let x = bounds.width * (workspace ? 0.90 : 0.77)
            let y = bounds.height * (workspace ? 0.75 : 0.67) + bounds.height * 0.012 * CGFloat(sin(light.orbit))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            terrain.frame = bounds
            earth.frame = CGRect(x: x-size/2, y: y-size/2, width: size, height: size)
            let refresh = lastRenderTime.map { still ? $0 != 0 : abs(time - $0) >= 0.5 / Self.framesPerSecond } ?? true
            if refresh {
                earth.contents = Self.renderer?.globe(at: light)
                lastRenderTime = time
            }
            CATransaction.commit()
        }
        deinit { timer?.invalidate() }
    }
}

struct StudioLunarHome<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background { StudioLunarScene(kind: .home) }
    }
}
