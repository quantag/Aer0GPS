import Foundation
import CoreLocation

struct Airport: Hashable {
    let iata: String
    let icao: String
    let name: String
    let city: String
    let country: String      // ISO 3166-1 alpha-2
    let lat: Double
    let lon: Double
    let timeZone: String     // IANA, e.g. "Europe/Oslo"

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    var tz: TimeZone? { TimeZone(identifier: timeZone) }
    /// "Bergen Airport Flesland, Bergen (NO)"
    var title: String { city.isEmpty || name.contains(city) ? "\(name) (\(country))" : "\(name), \(city) (\(country))" }
}

/// Offline airport database: every airport with an IATA code (~8,000), bundled as airports.tsv.
/// Built from the airportsdata package (MIT, github.com/mborsetti/airportsdata).
/// Columns: IATA ICAO name city country lat lon tz.
final class Airports {
    static let shared = Airports()

    private(set) var all: [Airport] = []
    private var byIATA: [String: Airport] = [:]
    private var byICAO: [String: Airport] = [:]

    private init() {
        guard let url = Bundle.main.url(forResource: "airports", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 8, let lat = Double(f[5]), let lon = Double(f[6]) else { continue }
            let a = Airport(iata: f[0], icao: f[1], name: f[2], city: f[3], country: f[4],
                            lat: lat, lon: lon, timeZone: f[7])
            all.append(a)
            byIATA[a.iata] = a
            if !a.icao.isEmpty { byICAO[a.icao] = a }
        }
    }

    /// Looks up a 3-letter IATA or 4-letter ICAO code (case-insensitive).
    func find(_ code: String) -> Airport? {
        let c = code.trimmingCharacters(in: .whitespaces).uppercased()
        return c.count == 4 ? byICAO[c] : byIATA[c]
    }

    /// Nearest airport within `maxKm` of the coordinate.
    func nearest(lat: Double, lon: Double, maxKm: Double = 10) -> Airport? {
        var best: Airport?
        var bestD = maxKm * 1000
        let dLatMax = maxKm / 111.0
        for a in all where abs(a.lat - lat) <= dLatMax {
            let d = Geo.distance(lat, lon, a.lat, a.lon)
            if d < bestD { bestD = d; best = a }
        }
        return best
    }

    /// Code matches first, then city / name matches. Used for the airport search field.
    func search(_ query: String, limit: Int = 6) -> [Airport] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        let up = q.uppercased()
        var result: [Airport] = []
        var seen = Set<String>()
        func add(_ a: Airport) {
            if result.count < limit, seen.insert(a.iata).inserted { result.append(a) }
        }
        if let a = find(up) { add(a) }
        for a in all where a.iata.hasPrefix(up) || a.icao == up { add(a) }
        for a in all where a.city.range(of: q, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil { add(a) }
        for a in all where a.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil { add(a) }
        return result
    }
}

/// Spherical-earth helpers (mean radius), good to ~0.5 % — plenty for flight statistics.
enum Geo {
    static let earthRadius = 6_371_008.8

    /// Great-circle distance in metres.
    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = p2 - p1, dl = (lon2 - lon1) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadius * asin(min(1, h.squareRoot()))
    }

    /// Points along the great circle from a to b (inclusive), as (lat, lon) in degrees.
    static func greatCircle(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double,
                            steps: Int = 64) -> [(Double, Double)] {
        func vec(_ lat: Double, _ lon: Double) -> SIMD3<Double> {
            let la = lat * .pi / 180, lo = lon * .pi / 180
            return SIMD3(cos(la) * cos(lo), cos(la) * sin(lo), sin(la))
        }
        let a = vec(lat1, lon1), b = vec(lat2, lon2)
        let omega = acos(min(1, max(-1, (a * b).sum())))
        guard omega > 1e-9 else { return [(lat1, lon1), (lat2, lon2)] }
        return (0...steps).map { i in
            let t = Double(i) / Double(steps)
            let v = (sin((1 - t) * omega) * a + sin(t * omega) * b) / sin(omega)
            return (asin(min(1, max(-1, v.z))) * 180 / .pi, atan2(v.y, v.x) * 180 / .pi)
        }
    }
}
