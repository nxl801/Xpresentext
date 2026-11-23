import Foundation
import ImageIO
import simd

@main struct CheckLunarScene {
    static func main() throws {
        let assets = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let renderer = StudioLunarRenderer(earthURL: assets.appendingPathComponent("Earth.jpg")),
              CGImageSourceCreateWithURL(assets.appendingPathComponent("LunarHorizon.jpg") as CFURL, nil) != nil
        else { throw CocoaError(.fileReadCorruptFile) }
        func point(_ x: Float, _ y: Float) -> SIMD3<Float> {
            SIMD3(x, y, sqrt(1 - x*x - y*y))
        }
        let opening = StudioLunarLight(time: 0)
        // The screen's upper half opens in daylight; the lower half is in night.
        precondition(simd_dot(point(0,0.7), opening.sun) > 0.6)
        precondition(simd_dot(point(0,-0.7), opening.sun) < -0.6)
        precondition(opening.sun.y > 4 * abs(opening.sun.x))
        let alignment = StudioLunarLight(time: 60)
        let center = point(-0.17, 0), edge = point(0.17, 0)
        precondition(opening.sunlight(at: center) == 1)
        precondition(alignment.sunlight(at: center) < 0.02)
        precondition((0.1...0.9).contains(alignment.sunlight(at: edge)))
        precondition(alignment.sunlight(at: point(-0.75,0.25)) == 1)
        precondition(StudioLunarLight(time: 66).sunlight(at: center) == 1)
        precondition(StudioLunarLight(time: 180).sunlight(at: center) == 1)
        func pixels(_ time: Double) -> Data {
            renderer.globe(at: .init(time: time))!.dataProvider!.data! as Data
        }
        precondition(pixels(0) == pixels(0))
        precondition(pixels(0) != pixels(12))
        precondition(abs(StudioLunarLight(time: 24).rotation - opening.rotation - .pi / 2) < 0.0001)
        var previous = pixels(0)
        for frame in 1...30 {
            let next = pixels(Double(frame) / 30)
            precondition(next != previous, "Successive frames reused the same globe")
            previous = next
        }
        print("PASS fixed lunar view, upper-lit quarter phase, umbra, penumbra, clear sunlight, orbit, rotation and still frame")
    }
}
