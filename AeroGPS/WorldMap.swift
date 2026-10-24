import Foundation
import CoreLocation

/// Web-Mercator in unit space: x in 0...1 (lon -180...180), y in 0...1 (lat +85 at top ... -85 at bottom).
enum Mercator {
    static let maxLat = 85.05112878
    /// Ground metres covered by one mercator unit (full world width) at the equator.
    static let earthCircumference = 40_075_016.686

    static func project(_ c: CLLocationCoordinate2D) -> SIMD2<Double> {
        project(lat: c.latitude, lon: c.longitude)
    }

    static func project(lat: Double, lon: Double) -> SIMD2<Double> {
        let la = min(max(lat, -maxLat), maxLat) * .pi / 180
        let x = (lon + 180) / 360
        let y = 0.5 - log(tan(.pi / 4 + la / 2)) / (2 * .pi)
        return SIMD2(x, y)
    }

    static func latitude(y: Double) -> Double {
        atan(sinh(.pi * (1 - 2 * y))) * 180 / .pi
    }

    static func longitude(x: Double) -> Double {
        x * 360 - 180
    }

    /// Ground metres per mercator unit at the given latitude.
    static func metersPerUnit(atLatitude lat: Double) -> Double {
        earthCircumference * cos(lat * .pi / 180)
    }
}

struct MapShape {
    let rings: [[SIMD2<Float>]]
    let minX: Float, minY: Float, maxX: Float, maxY: Float

    init(rings: [[SIMD2<Float>]]) {
        self.rings = rings
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for r in rings {
            for p in r {
                lo = pointwiseMin(lo, p)
                hi = pointwiseMax(hi, p)
            }
        }
        minX = lo.x; minY = lo.y; maxX = hi.x; maxY = hi.y
    }
}

struct MapCity {
    let point: SIMD2<Float>
    let rank: Int          // Natural Earth scalerank: 0 = most important
    let name: String
}

/// Offline world map built from Natural Earth 1:50m data (public domain), bundled as worldmap.bin.
/// Generated offline; see the README for the file layout.
final class WorldMap {
    static let shared = WorldMap.load()

    var landFull: [MapShape] = [], landCoarse: [MapShape] = []
    var lakesFull: [MapShape] = [], lakesCoarse: [MapShape] = []
    var bordersFull: [MapShape] = [], bordersCoarse: [MapShape] = []
    var cities: [MapCity] = []
    var loadError: String?

    private static func load() -> WorldMap {
        let map = WorldMap()
        guard let url = Bundle.main.url(forResource: "worldmap", withExtension: "bin") else {
            map.loadError = "worldmap.bin missing from app bundle"
            return map
        }
        do {
            let data = try Data(contentsOf: url)
            var r = BinaryReader(data: data)
            guard try r.bytes(4) == Data("WMAP".utf8) else { throw BinaryReader.Failure() }
            guard try r.u32() == 1 else { throw BinaryReader.Failure() }
            let layerCount = Int(try r.u32())
            var layers: [[MapShape]] = []
            for _ in 0..<layerCount {
                let shapeCount = Int(try r.u32())
                var shapes: [MapShape] = []
                shapes.reserveCapacity(shapeCount)
                for _ in 0..<shapeCount {
                    let ringCount = Int(try r.u32())
                    var rings: [[SIMD2<Float>]] = []
                    for _ in 0..<ringCount {
                        rings.append(try r.points(Int(try r.u32())))
                    }
                    shapes.append(MapShape(rings: rings))
                }
                layers.append(shapes)
            }
            guard layers.count >= 6 else { throw BinaryReader.Failure() }
            map.landFull = layers[0]; map.landCoarse = layers[1]
            map.lakesFull = layers[2]; map.lakesCoarse = layers[3]
            map.bordersFull = layers[4]; map.bordersCoarse = layers[5]

            let cityCount = Int(try r.u32())
            for _ in 0..<cityCount {
                let x = try r.f32(), y = try r.f32()
                let rank = Int(try r.u8())
                let name = String(decoding: try r.bytes(Int(try r.u8())), as: UTF8.self)
                map.cities.append(MapCity(point: SIMD2(x, y), rank: rank, name: name))
            }
        } catch {
            map.loadError = "worldmap.bin is damaged"
        }
        return map
    }
}

private struct BinaryReader {
    struct Failure: Error {}

    let data: Data
    var offset = 0

    private mutating func take(_ n: Int) throws -> Data {
        guard n >= 0, offset + n <= data.count else { throw Failure() }
        let start = data.startIndex + offset
        offset += n
        return data.subdata(in: start..<(start + n))
    }

    mutating func bytes(_ n: Int) throws -> Data { try take(n) }

    mutating func u8() throws -> UInt8 { try take(1).first! }

    mutating func u32() throws -> UInt32 {
        let d = try take(4)
        return d.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    }

    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }

    /// n little-endian (Float x, Float y) pairs, copied in one go.
    mutating func points(_ n: Int) throws -> [SIMD2<Float>] {
        guard n > 0 else { return [] }
        let d = try take(n * 8)
        return d.withUnsafeBytes { raw in
            (0..<n).map { i in
                SIMD2(Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 8, as: UInt32.self))),
                      Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 8 + 4, as: UInt32.self))))
            }
        }
    }
}
