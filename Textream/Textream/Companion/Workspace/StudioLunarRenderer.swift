import Foundation
import CoreGraphics
import ImageIO
import simd

/// Distances in Earth radii. The orbit and disc sizes are composed for a
/// readable eclipse at window scale. Globe and shadow use the same sun vector.
struct StudioLunarLight {
    let rotation: Float
    let orbit: Float
    let sun: SIMD3<Float>
    private let moon = SIMD3<Float>(0, 0, 18)

    init(time: TimeInterval) {
        rotation = Float((time / 96).truncatingRemainder(dividingBy: 1)) * 2 * .pi + 0.46
        orbit = Float((time / 240).truncatingRemainder(dividingBy: 1)) * 2 * .pi
        // Begin at quarter phase with the Sun high above the local horizon.
        // At 60 seconds the Moon crosses the Earth–Sun line. The small orbital
        // inclination gives the eclipse track a slight lateral offset.
        let phase = Float.pi / 2 - orbit
        let roll: Float = 12 * .pi / 180
        let across = sin(phase)
        sun = simd_normalize(SIMD3<Float>(-sin(roll) * across + 0.010 * cos(phase),
                                          cos(roll) * across, cos(phase)))
    }

    /// The finite solar disc produces a soft penumbra around the dark core.
    func sunlight(at point: SIMD3<Float>) -> Float {
        let toMoon = moon - point
        let alongRay = simd_dot(toMoon, sun)
        guard alongRay > 0 else { return 1 }
        let offAxis = simd_length(toMoon - alongRay * sun)
        let spread = alongRay * 0.009
        let t = min(1, max(0, (offAxis - (0.34 - spread)) / (2 * spread)))
        return t * t * (3 - 2 * t)
    }
}

/// Fixed sphere projections are shared across frames. Only the small globe's
/// pixels are animated. The full-window terrain stays in its own static layer.
final class StudioLunarRenderer {
    private struct Sample {
        let offset: Int
        let normal: SIMD3<Float>
        let column: Int
        let row: Int
        let alpha: UInt32
    }

    let diameter: Int
    private let width = 2048
    private let height = 1024
    private let map: [UInt32]
    private let samples: [Sample]
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private let format = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        .union(.byteOrder32Big)

    init?(earthURL: URL, diameter: Int = 288) {
        self.diameter = diameter
        guard let source = CGImageSourceCreateWithURL(earthURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var texture = [UInt32](repeating: 0, count: width * height)
        let loaded = texture.withUnsafeMutableBytes { [width, height, space, format] bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: format.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0,y: 0,width: width,height: height))
            return true
        }
        guard loaded else { return nil }
        map = texture
        var projection = [Sample]()
        let radius = Float(diameter) / 2 - 1
        let tilt: Float = 0.409
        for y in 0..<diameter {
            for x in 0..<diameter {
                let nx = (Float(x) + 0.5 - Float(diameter)/2) / radius
                let ny = (Float(diameter)/2 - Float(y) - 0.5) / radius
                let r2 = nx * nx + ny * ny
                guard r2 < 1 else { continue }
                let nz = sqrt(1 - r2)
                let lon = atan2(nx*cos(tilt) + ny*sin(tilt), nz)
                let lat = asin(max(-1, min(1, ny*cos(tilt) - nx*sin(tilt))))
                let row = min(height-1, Int((0.5 - lat / .pi) * Float(height)))
                projection.append(Sample(offset: y*diameter+x, normal: SIMD3(nx,ny,nz),
                    column: Int((0.5 + lon/(2 * .pi))*Float(width)), row: row*width,
                    alpha: UInt32(255 * min(1, (1-sqrt(r2))*radius))))
            }
        }
        samples = projection
    }

    func globe(at light: StudioLunarLight) -> CGImage? {
        var rgba = [UInt32](repeating: 0, count: diameter * diameter)
        let longitude = light.rotation * Float(width) / (2 * .pi)
        let shift = Int(longitude)
        let fraction = longitude - Float(shift)
        for s in samples {
            let column = s.column + shift
            let left = map[s.row + (column & (width - 1))]
            let right = map[s.row + ((column + 1) & (width - 1))]
            let cosine = max(0, simd_dot(s.normal, light.sun))
            let direct = sqrt(cosine) * light.sunlight(at: s.normal)
            let brightness = 0.075 + 0.98 * direct
            let edge = 1-s.normal.z
            let rim = edge*edge*edge*(0.10 + direct)
            func channel(_ bit: Int, _ glow: Float) -> UInt32 {
                let a = Float((left >> bit) & 255), b = Float((right >> bit) & 255)
                let value = a + (b - a) * fraction
                return UInt32(min(255, value*brightness + glow*rim)) * s.alpha / 255
            }
            let red = channel(0, 45), green = channel(8, 108), blue = channel(16, 179)
            rgba[s.offset] = red | (green << 8) | (blue << 16) | (s.alpha << 24)
        }
        let data = rgba.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: diameter, height: diameter, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: diameter*4, space: space, bitmapInfo: format, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
