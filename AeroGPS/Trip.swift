import Foundation
import CoreLocation

// MARK: - Recorded point

/// One recorded GPS fix. Stored on disk as one CSV line per point (see `csvLine`).
struct TripPoint: Hashable {
    var t: Double               // fix time, seconds since 1970 (UTC)
    var lat: Double
    var lon: Double
    var alt: Float              // m above mean sea level
    var hAcc: Float             // m, negative = invalid
    var vAcc: Float             // m, negative = altitude invalid
    var spd: Float              // m/s ground speed, negative = invalid
    var spdAcc: Float           // m/s, negative = unknown
    var crs: Float              // degrees true, negative = invalid

    init(_ l: CLLocation) {
        t = l.timestamp.timeIntervalSince1970
        lat = l.coordinate.latitude
        lon = l.coordinate.longitude
        alt = Float(l.altitude)
        hAcc = Float(l.horizontalAccuracy)
        vAcc = Float(l.verticalAccuracy)
        spd = Float(l.speed)
        spdAcc = Float(l.speedAccuracy)
        crs = Float(l.course)
    }

    /// Parses a line written by `csvLine`: t,lat,lon,alt,hAcc,vAcc,spd,spdAcc,crs
    init?(csv line: Substring) {
        let f = line.split(separator: ",", omittingEmptySubsequences: false)
        guard f.count >= 9,
              let t = Double(f[0]), let lat = Double(f[1]), let lon = Double(f[2]),
              let alt = Float(f[3]), let hAcc = Float(f[4]), let vAcc = Float(f[5]),
              let spd = Float(f[6]), let spdAcc = Float(f[7]), let crs = Float(f[8]) else { return nil }
        self.t = t; self.lat = lat; self.lon = lon; self.alt = alt
        self.hAcc = hAcc; self.vAcc = vAcc; self.spd = spd; self.spdAcc = spdAcc; self.crs = crs
    }

    var csvLine: String {
        String(format: "%.2f,%.7f,%.7f,%.1f,%.1f,%.1f,%.2f,%.2f,%.1f",
               t, lat, lon, alt, hAcc, vAcc, spd, spdAcc, crs)
    }

    var date: Date { Date(timeIntervalSince1970: t) }
    var hasGoodPosition: Bool { hAcc >= 0 && hAcc <= 100 }
    var hasGoodAltitude: Bool { vAcc >= 0 && vAcc <= 50 }
    var mercator: SIMD2<Double> { Mercator.project(lat: lat, lon: lon) }

    static func parse(_ text: String) -> [TripPoint] {
        text.split(separator: "\n").compactMap { TripPoint(csv: $0) }
    }
}

// MARK: - Statistics

/// Statistics derived from a trip's points. Cached in the trip's JSON so the list never loads tracks.
struct TripStats: Codable, Hashable {
    /// Ground speed above which the aircraft counts as airborne (35 m/s ≈ 68 kt ≈ 126 km/h).
    static let airborneSpeed: Float = 35

    var pointCount = 0
    var firstFix: Date?
    var lastFix: Date?
    /// First / last moment of sustained flying speed.
    var airborneStart: Date?
    var airborneEnd: Date?
    /// Recording began / ended while already flying, so takeoff / landing were not seen.
    var startedAirborne = false
    var endedAirborne = false
    var distance: Double = 0            // m along the recorded track
    var maxSpeed: Double = 0            // m/s ground speed
    var maxAltitude: Double?            // m MSL
    var maxClimb: Double = 0            // m/s
    var maxDescent: Double = 0          // m/s (positive number)
    var longestGap: Double = 0          // s between consecutive fixes
    var startLat: Double?, startLon: Double?
    var endLat: Double?, endLon: Double?
    var takeoffLat: Double?, takeoffLon: Double?
    var landingLat: Double?, landingLon: Double?
    // Added in stats version 2 (optional so stats saved by older versions still decode).
    var version: Int?
    var movingTime: Double?             // s at more than 1.5 m/s (5 km/h)
    var minAltitude: Double?            // m MSL
    var ascent: Double?                 // m total climb (10 m hysteresis)
    var descent: Double?                // m total descent

    /// Bump when `compute` changes; trips with older stats are recomputed on load.
    static let currentVersion = 2

    var takeoff: Date? { startedAirborne ? nil : airborneStart }
    var landing: Date? { endedAirborne ? nil : airborneEnd }
    var duration: TimeInterval? {
        guard let a = firstFix, let b = lastFix else { return nil }
        return b.timeIntervalSince(a)
    }
    /// Time at flying speed (takeoff to landing when both were recorded).
    var airTime: TimeInterval? {
        guard let a = airborneStart, let b = airborneEnd else { return nil }
        return b.timeIntervalSince(a)
    }

    static func compute(_ pts: [TripPoint]) -> TripStats {
        var s = TripStats()
        s.version = currentVersion
        s.pointCount = pts.count
        guard let first = pts.first, let last = pts.last else { return s }
        s.firstFix = first.date
        s.lastFix = last.date

        // Gaps between fixes.
        for i in pts.indices.dropFirst() {
            s.longestGap = max(s.longestGap, pts[i].t - pts[i - 1].t)
        }

        // Positions and distance: accurate fixes only, rejecting jumps faster than 400 m/s.
        let good = pts.filter(\.hasGoodPosition)
        if let g = good.first { s.startLat = g.lat; s.startLon = g.lon }
        if let g = good.last { s.endLat = g.lat; s.endLon = g.lon }
        var prev: TripPoint?
        var rejected = 0
        for p in good {
            guard let q = prev else { prev = p; continue }
            let d = Geo.distance(q.lat, q.lon, p.lat, p.lon)
            let dt = p.t - q.t
            if dt > 0 && d / dt < 400 {
                s.distance += d
                prev = p
                rejected = 0
            } else {
                rejected += 1
                if rejected >= 5 { prev = p; rejected = 0 }   // the earlier point was the outlier
            }
        }

        // Maximum ground speed: trustworthy speeds only.
        for p in pts where p.spd >= 0 && p.spd < 400 && p.hasGoodPosition && (p.spdAcc < 0 || p.spdAcc <= 5) {
            s.maxSpeed = max(s.maxSpeed, Double(p.spd))
        }

        // Altitude and vertical speed (over 30–90 s windows to smooth GPS altitude noise).
        let alts = pts.filter(\.hasGoodAltitude)
        s.maxAltitude = alts.map { Double($0.alt) }.max()
        s.minAltitude = alts.map { Double($0.alt) }.min()

        // Total ascent / descent with 10 m hysteresis (filters GPS altitude noise).
        if let first = alts.first {
            var ref = Double(first.alt), up = 0.0, down = 0.0
            for p in alts {
                let a = Double(p.alt)
                if a > ref + 10 { up += a - ref; ref = a } else if a < ref - 10 { down += ref - a; ref = a }
            }
            s.ascent = up
            s.descent = down
        }

        // Moving time: intervals of at most 30 s between two fixes that are both moving.
        var moving = 0.0
        for i in pts.indices.dropFirst() {
            let a = pts[i - 1], b = pts[i], dt = b.t - a.t
            if dt > 0 && dt <= 30 && a.spd >= 1.5 && b.spd >= 1.5 { moving += dt }
        }
        s.movingTime = moving
        var j = 0
        for i in alts.indices {
            if j < i { j = i }
            while j < alts.count - 1 && alts[j].t - alts[i].t < 30 { j += 1 }
            let dt = alts[j].t - alts[i].t
            guard dt >= 30 && dt <= 90 else { continue }
            let rate = Double(alts[j].alt - alts[i].alt) / dt
            guard abs(rate) < 100 else { continue }
            s.maxClimb = max(s.maxClimb, rate)
            s.maxDescent = max(s.maxDescent, -rate)
        }

        // Airborne period: first / last point at flying speed that is sustained
        // (at least 75 % of the speed readings within the next / previous 2 minutes).
        let sp = pts.filter { $0.spd >= 0 }
        func fast(_ k: Int) -> Bool { sp[k].spd >= airborneSpeed }
        func sustained(_ k: Int, forward: Bool) -> Bool {
            var n = 0, f = 0, m = k
            while m >= 0 && m < sp.count && abs(sp[m].t - sp[k].t) <= 120 {
                n += 1
                if fast(m) { f += 1 }
                m += forward ? 1 : -1
            }
            return Double(f) >= 0.75 * Double(n)
        }
        if let a = sp.indices.first(where: { fast($0) && sustained($0, forward: true) }),
           let b = sp.indices.last(where: { fast($0) && sustained($0, forward: false) }), a <= b {
            s.airborneStart = sp[a].date
            s.airborneEnd = sp[b].date
            s.startedAirborne = a == 0
            s.endedAirborne = b == sp.count - 1
            if !s.startedAirborne { s.takeoffLat = sp[a].lat; s.takeoffLon = sp[a].lon }
            if !s.endedAirborne { s.landingLat = sp[b].lat; s.landingLon = sp[b].lon }
        }
        return s
    }
}

// MARK: - Trip

enum TripKind: String, Codable, CaseIterable, Identifiable {
    case airplane
    case car

    var id: String { rawValue }
    var name: String { self == .airplane ? "Airplane" : "Car" }
    var icon: String { self == .airplane ? "airplane" : "car.fill" }
}

struct Trip: Codable, Identifiable, Hashable {
    var id = UUID()
    var created = Date()
    var kind = TripKind.airplane
    /// Airplane: IATA (or ICAO) code. Car: optional free text (city, address…).
    var from = ""
    var to = ""
    var flightNumber = ""
    var airline = ""
    var aircraft = ""
    var seat = ""
    var vehicle = ""            // Car: model, plate, …
    /// Free-text comment about the whole trip (shown as "Comment").
    var notes = ""
    /// Notes added during (or after) the trip: text, fuel stops, meals — each with time and position.
    var tripNotes: [TripNote] = []
    /// from / to were filled automatically from the track (so a better detection may replace them).
    var autoFrom = false
    var autoTo = false
    /// True until the user stops recording. Survives the app being killed, so recording resumes on relaunch.
    var isRecording = false
    var stats = TripStats()

    var isFlight: Bool { kind == .airplane }
    var fromAirport: Airport? { isFlight ? Airports.shared.find(from) : nil }
    var toAirport: Airport? { isFlight ? Airports.shared.find(to) : nil }
    var date: Date { stats.firstFix ?? created }

    /// "BGO → AMS"; for Car "Bergen → Voss", "Bergen → …" or "Drive" when no route was entered.
    var route: String {
        if isFlight {
            let a = from.isEmpty ? "???" : from.uppercased()
            let b = to.isEmpty ? "???" : to.uppercased()
            return "\(a) → \(b)"
        }
        if from.isEmpty && to.isEmpty { return "Drive" }
        return "\(from.isEmpty ? "…" : from) → \(to.isEmpty ? "…" : to)"
    }

    var title: String {
        guard isFlight, !flightNumber.isEmpty else { return route }
        return "\(route)  \(flightNumber.uppercased())"
    }

    /// Time spent travelling: air time for flights, moving time for drives.
    var travelTime: TimeInterval? { isFlight ? stats.airTime : stats.movingTime }

    /// Departure airport: nearest to the takeoff roll, or to the first fix if that was on the ground.
    var detectedDeparture: Airport? {
        if let la = stats.takeoffLat, let lo = stats.takeoffLon { return Airports.shared.nearest(lat: la, lon: lo) }
        if !stats.startedAirborne, let la = stats.startLat, let lo = stats.startLon {
            return Airports.shared.nearest(lat: la, lon: lo)
        }
        return nil
    }

    /// Arrival airport: nearest to the landing roll, or to the last fix if that was on the ground.
    var detectedArrival: Airport? {
        if let la = stats.landingLat, let lo = stats.landingLon { return Airports.shared.nearest(lat: la, lon: lo) }
        if !stats.endedAirborne, stats.airborneStart != nil, let la = stats.endLat, let lo = stats.endLon {
            return Airports.shared.nearest(lat: la, lon: lo)
        }
        return nil
    }

    /// Fills departure / arrival from the track. Never replaces a code the user typed unless `overwrite`.
    /// Returns true if anything changed.
    @discardableResult
    mutating func autoDetectAirports(overwrite: Bool = false) -> Bool {
        guard isFlight else { return false }
        var changed = false
        if overwrite || from.isEmpty || autoFrom, let a = detectedDeparture, a.iata != from || !autoFrom {
            from = a.iata; autoFrom = true; changed = true
        }
        if overwrite || to.isEmpty || autoTo, let a = detectedArrival, a.iata != to || !autoTo {
            to = a.iata; autoTo = true; changed = true
        }
        return changed
    }

    /// Great-circle distance between the two airports, if both are known.
    var routeDistance: Double? {
        guard let a = fromAirport, let b = toAirport else { return nil }
        return Geo.distance(a.lat, a.lon, b.lat, b.lon)
    }

    /// File-name friendly "2026-11-14 BGO-AMS DY604"
    var fileName: String {
        let d = Fmt.day.string(from: date)
        var parts = [d]
        if isFlight {
            if !from.isEmpty || !to.isEmpty { parts.append("\(from.isEmpty ? "XXX" : from)-\(to.isEmpty ? "XXX" : to)") }
            if !flightNumber.isEmpty { parts.append(flightNumber) }
        } else {
            parts.append(from.isEmpty && to.isEmpty ? "Drive" : "\(from.isEmpty ? "start" : from)-\(to.isEmpty ? "end" : to)")
        }
        let joined = parts.joined(separator: " ")
        let name = isFlight ? joined.uppercased() : joined
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: bad).joined(separator: "_")
    }
}

extension Trip {
    /// Missing keys get their defaults, so trips saved by older versions (no `kind`, `vehicle`) still load
    /// (as Airplane trips).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? id
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? created
        kind = (try? c.decodeIfPresent(TripKind.self, forKey: .kind)) ?? .airplane
        from = try c.decodeIfPresent(String.self, forKey: .from) ?? ""
        to = try c.decodeIfPresent(String.self, forKey: .to) ?? ""
        flightNumber = try c.decodeIfPresent(String.self, forKey: .flightNumber) ?? ""
        airline = try c.decodeIfPresent(String.self, forKey: .airline) ?? ""
        aircraft = try c.decodeIfPresent(String.self, forKey: .aircraft) ?? ""
        seat = try c.decodeIfPresent(String.self, forKey: .seat) ?? ""
        vehicle = try c.decodeIfPresent(String.self, forKey: .vehicle) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        tripNotes = (try? c.decodeIfPresent([TripNote].self, forKey: .tripNotes)) ?? []
        autoFrom = try c.decodeIfPresent(Bool.self, forKey: .autoFrom) ?? false
        autoTo = try c.decodeIfPresent(Bool.self, forKey: .autoTo) ?? false
        isRecording = try c.decodeIfPresent(Bool.self, forKey: .isRecording) ?? false
        stats = (try? c.decodeIfPresent(TripStats.self, forKey: .stats)) ?? TripStats()
    }
}

// MARK: - Formatting

enum Fmt {
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// "HH:mm" in the airport's time zone (when known) plus the zone abbreviation.
    static func localTime(_ d: Date, _ airport: Airport?) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm zzz"
        if let tz = airport?.tz { f.timeZone = tz }
        return f.string(from: d)
    }

    /// "2h 05m", "45m", "12s"
    static func duration(_ s: TimeInterval?) -> String {
        guard let s, s >= 0 else { return "—" }
        let total = Int(s.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return "\(m)m" }
        return "\(total)s"
    }

    /// Flights in knots (km/h), drives in km/h (mph).
    static func speed(_ mps: Double?, _ kind: TripKind = .airplane) -> String {
        guard let v = mps, v > 0 else { return "—" }
        return kind == .airplane
            ? String(format: "%.0f kt  (%.0f km/h)", v * 1.943844, v * 3.6)
            : String(format: "%.0f km/h  (%.0f mph)", v * 3.6, v * 2.236936)
    }

    /// Flights in feet (m), drives in metres (ft).
    static func altitude(_ m: Double?, _ kind: TripKind = .airplane) -> String {
        guard let m else { return "—" }
        return kind == .airplane
            ? String(format: "%@ ft  (%@ m)", group(m * 3.28084), group(m))
            : String(format: "%@ m  (%@ ft)", group(m), group(m * 3.28084))
    }

    /// Short single-unit forms for compact rows.
    static func speedShort(_ mps: Double, _ kind: TripKind) -> String {
        mps > 0 ? (kind == .airplane ? "\(group(mps * 1.943844)) kt" : "\(group(mps * 3.6)) km/h") : "—"
    }
    static func altitudeShort(_ m: Double?, _ kind: TripKind) -> String {
        guard let m else { return "—" }
        return kind == .airplane ? "\(group(m * 3.28084)) ft" : "\(group(m)) m"
    }

    static func distance(_ m: Double?) -> String {
        guard let m, m > 0 else { return "—" }
        return String(format: "%@ km  (%@ nm)", group(m / 1000), group(m / 1852))
    }

    static func vspeed(_ mps: Double) -> String {
        mps > 0 ? String(format: "%@ ft/min", group(mps * 196.850)) : "—"
    }

    static func group(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v.rounded())) ?? String(format: "%.0f", v)
    }
}

// MARK: - Export

enum TripExport {

    /// GPX 1.1 with one <trk> per trip; opens in Google Earth, GPX viewers, flight-log sites.
    static func gpx(_ trips: [(Trip, [TripPoint])]) -> String {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="AeroGPS" xmlns="http://www.topografix.com/GPX/1/1">

        """
        // GPX requires all waypoints (the trips' notes) before the tracks.
        for (trip, _) in trips { out += gpxWaypoints(trip) }
        for (trip, pts) in trips {
            out += "  <trk>\n    <name>\(xml(trip.title))</name>\n"
            let desc = [trip.airline, trip.aircraft, trip.notes].filter { !$0.isEmpty }.joined(separator: " · ")
            if !desc.isEmpty { out += "    <desc>\(xml(desc))</desc>\n" }
            out += "    <trkseg>\n"
            for p in pts where p.hAcc >= 0 {
                out += String(format: "      <trkpt lat=\"%.7f\" lon=\"%.7f\">", p.lat, p.lon)
                if p.vAcc >= 0 { out += String(format: "<ele>%.1f</ele>", p.alt) }
                out += "<time>\(Fmt.isoFrac.string(from: p.date))</time>"
                if p.spd >= 0 || p.crs >= 0 {
                    out += "<extensions>"
                    if p.spd >= 0 { out += String(format: "<speed>%.2f</speed>", p.spd) }
                    if p.crs >= 0 { out += String(format: "<course>%.1f</course>", p.crs) }
                    out += "</extensions>"
                }
                out += "</trkpt>\n"
            }
            out += "    </trkseg>\n  </trk>\n"
        }
        out += "</gpx>\n"
        return out
    }

    /// Every recorded fix of one trip.
    static func pointsCSV(_ pts: [TripPoint]) -> String {
        var out = "time_utc,lat,lon,alt_m,h_acc_m,v_acc_m,speed_mps,speed_acc_mps,course_deg\n"
        for p in pts {
            out += String(format: "%@,%.7f,%.7f,%.1f,%.1f,%.1f,%.2f,%.2f,%.1f\n",
                          Fmt.isoFrac.string(from: p.date), p.lat, p.lon, p.alt, p.hAcc, p.vAcc, p.spd, p.spdAcc, p.crs)
        }
        return out
    }

    /// Travel logbook: one row per trip, oldest first. Flight-only columns are empty for Car trips.
    static func logbookCSV(_ trips: [Trip]) -> String {
        let cols = ["date", "type", "flight", "airline", "aircraft", "seat", "vehicle", "from", "from_name", "to", "to_name",
                    "first_fix_utc", "takeoff_utc", "landing_utc", "last_fix_utc", "air_time_min", "moving_min",
                    "recorded_min", "track_km", "route_km", "max_speed_kt", "max_speed_kmh", "max_alt_ft", "max_alt_m",
                    "max_climb_fpm", "max_descent_fpm", "ascent_m", "descent_m", "points", "note_count", "comment"]
        var out = cols.joined(separator: ",") + "\n"
        func t(_ d: Date?) -> String { d.map { Fmt.iso.string(from: $0) } ?? "" }
        func n(_ v: Double?, _ dec: Int = 0) -> String { v.map { String(format: "%.\(dec)f", $0) } ?? "" }
        for trip in trips.sorted(by: { $0.date < $1.date }) {
            let s = trip.stats
            let fl = trip.isFlight
            let row: [String] = [
                Fmt.day.string(from: trip.date), trip.kind.name,
                fl ? trip.flightNumber : "", fl ? trip.airline : "", fl ? trip.aircraft : "", fl ? trip.seat : "",
                fl ? "" : trip.vehicle,
                trip.from, trip.fromAirport?.name ?? "", trip.to, trip.toAirport?.name ?? "",
                t(s.firstFix), fl ? t(s.takeoff) : "", fl ? t(s.landing) : "", t(s.lastFix),
                fl ? n(s.airTime.map { $0 / 60 }) : "", n(s.movingTime.map { $0 / 60 }), n(s.duration.map { $0 / 60 }),
                n(s.distance / 1000, 1), n(trip.routeDistance.map { $0 / 1000 }, 1),
                n(s.maxSpeed * 1.943844), n(s.maxSpeed * 3.6),
                n(s.maxAltitude.map { $0 * 3.28084 }), n(s.maxAltitude),
                n(s.maxClimb * 196.85), n(s.maxDescent * 196.85), n(s.ascent), n(s.descent),
                "\(s.pointCount)", "\(trip.tripNotes.count)", trip.notes,
            ]
            out += row.map(csvField).joined(separator: ",") + "\n"
        }
        return out
    }

    /// Human-readable summary of one trip.
    static func summary(_ trip: Trip) -> String {
        let s = trip.stats
        let k = trip.kind
        var lines = ["AeroGPS \(k == .airplane ? "flight" : "drive"): \(trip.title)"]
        func add(_ label: String, _ value: String) {
            lines.append("\(label):".padding(toLength: 12, withPad: " ", startingAt: 0) + value)
        }
        if !trip.isFlight {
            if !trip.from.isEmpty { add("From", trip.from) }
            if !trip.to.isEmpty { add("To", trip.to) }
            if !trip.vehicle.isEmpty { add("Vehicle", trip.vehicle) }
            if let d = s.firstFix { add("Start", Fmt.dateTime.string(from: d)) }
            if let d = s.lastFix { add("End", Fmt.dateTime.string(from: d)) }
            add("Driving", Fmt.duration(s.movingTime))
            add("Recorded", Fmt.duration(s.duration))
            add("Distance", Fmt.distance(s.distance))
            add("Max speed", Fmt.speed(s.maxSpeed, k))
            if let m = s.movingTime, m > 60 { add("Avg speed", Fmt.speed(s.distance / m, k)) }
            add("Max alt", Fmt.altitude(s.maxAltitude, k))
            add("Min alt", Fmt.altitude(s.minAltitude, k))
            add("Ascent", s.ascent.map { "\(Fmt.group($0)) m" } ?? "—")
            add("Descent", s.descent.map { "\(Fmt.group($0)) m" } ?? "—")
            add("Fixes", "\(s.pointCount), longest gap \(Fmt.duration(s.longestGap))")
            if !trip.notes.isEmpty { add("Comment", trip.notes) }
            lines += noteLines(trip)
            return lines.joined(separator: "\n") + "\n"
        }
        if let a = trip.fromAirport { lines.append("From:       \(a.iata) \(a.title)") }
        if let a = trip.toAirport { lines.append("To:         \(a.iata) \(a.title)") }
        for (label, v) in [("Airline", trip.airline), ("Aircraft", trip.aircraft), ("Seat", trip.seat)] where !v.isEmpty {
            add(label, v)
        }
        if let d = s.firstFix { lines.append("First fix:  \(Fmt.dateTime.string(from: d))") }
        if let d = s.takeoff { lines.append("Takeoff:    \(Fmt.localTime(d, trip.fromAirport))") }
        if let d = s.landing { lines.append("Landing:    \(Fmt.localTime(d, trip.toAirport))") }
        lines.append("Air time:   \(Fmt.duration(s.airTime))")
        lines.append("Recorded:   \(Fmt.duration(s.duration))")
        lines.append("Track:      \(Fmt.distance(s.distance))")
        if let r = trip.routeDistance { lines.append("Route (GC): \(Fmt.distance(r))") }
        lines.append("Max speed:  \(Fmt.speed(s.maxSpeed))")
        lines.append("Max alt:    \(Fmt.altitude(s.maxAltitude))")
        lines.append("Max climb:  \(Fmt.vspeed(s.maxClimb))")
        lines.append("Max desc.:  \(Fmt.vspeed(s.maxDescent))")
        lines.append("Fixes:      \(s.pointCount), longest gap \(Fmt.duration(s.longestGap))")
        if !trip.notes.isEmpty { lines.append("Comment:    \(trip.notes)") }
        lines += noteLines(trip)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Notes and costs for the text summary.
    private static func noteLines(_ trip: Trip) -> [String] {
        guard !trip.tripNotes.isEmpty else { return [] }
        var lines = ["", "Notes:"]
        for n in trip.tripNotes {
            let pos = n.lat.flatMap { la in n.lon.map { String(format: "  (%.5f, %.5f)", la, $0) } } ?? ""
            lines.append("  \(Fmt.time.string(from: n.date))  \(n.kind.name): \(n.headline)\(pos)")
            if let d = n.detail { lines.append("         \(d)") }
        }
        let c = NoteCosts(trip.tripNotes)
        if !c.isEmpty {
            lines.append("")
            if !c.fuel.isEmpty || !c.fuelAmount.isEmpty {
                lines.append("Fuel:       \(NoteCosts.text(c.fuel)), \(c.fuelAmountText)")
            }
            if !c.food.isEmpty { lines.append("Food:       \(NoteCosts.text(c.food))") }
            lines.append("Total cost: \(NoteCosts.text(c.total))")
        }
        return lines
    }

    static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func csvField(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
