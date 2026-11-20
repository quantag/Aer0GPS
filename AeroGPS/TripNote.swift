import Foundation

// MARK: - Note types

enum NoteKind: String, Codable, CaseIterable, Identifiable {
    case generic
    case fuel
    case food

    var id: String { rawValue }

    var name: String {
        switch self {
        case .generic: return "Generic"
        case .fuel:    return "Fueling"
        case .food:    return "Food"
        }
    }

    var icon: String {
        switch self {
        case .generic: return "note.text"
        case .fuel:    return "fuelpump.fill"
        case .food:    return "fork.knife"
        }
    }

    /// Used as the marker label on maps.
    var emoji: String {
        switch self {
        case .generic: return "📝"
        case .fuel:    return "⛽"
        case .food:    return "🍴"
        }
    }
}

// MARK: - Note

/// A note added to a trip: free text, a fuel stop or a meal. Keeps the time and GPS position where it was added.
struct TripNote: Codable, Identifiable, Hashable {
    static let fuelTypes = ["Petrol 95", "Petrol 98", "Diesel", "LPG", "CNG", "Electric", "Other"]

    var id = UUID()
    var date = Date()
    var kind = NoteKind.generic
    var text = ""
    /// Position when the note was added (nil if there was no GPS fix, or added after the trip).
    var lat: Double?
    var lon: Double?
    var alt: Double?
    /// Total price paid (fuel and food).
    var price: Double?
    var currency = ""
    /// Fuel amount: litres (kWh for Electric).
    var amount: Double?
    var fuelType = ""
    /// Food: what was eaten.
    var food = ""

    var hasPosition: Bool { lat != nil && lon != nil }
    var mercator: SIMD2<Double>? {
        guard let lat, let lon else { return nil }
        return Mercator.project(lat: lat, lon: lon)
    }

    /// "L" or "kWh".
    var unit: String { fuelType == "Electric" ? "kWh" : "L" }

    /// Price per litre / kWh.
    var unitPrice: Double? {
        guard let p = price, let a = amount, a > 0 else { return nil }
        return p / a
    }

    var priceText: String? { price.map { Fmt.money($0, currency) } }

    /// One line for lists: "42.3 L Diesel · €75.10 (€1.78/L)", "Pizza · €18.00", or the note text.
    var headline: String {
        switch kind {
        case .fuel:
            var parts: [String] = []
            let what = [amount.map { "\(Fmt.decimal($0)) \(unit)" }, fuelType.isEmpty ? nil : fuelType]
                .compactMap { $0 }.joined(separator: " ")
            if !what.isEmpty { parts.append(what) }
            if let p = priceText {
                parts.append(unitPrice.map { "\(p) (\(Fmt.money($0, currency, decimals: 3))/\(unit))" } ?? p)
            }
            return parts.isEmpty ? "Fueling" : parts.joined(separator: " · ")
        case .food:
            let parts = [food.isEmpty ? nil : food, priceText].compactMap { $0 }
            return parts.isEmpty ? "Food" : parts.joined(separator: " · ")
        case .generic:
            return text.isEmpty ? "Note" : text
        }
    }

    /// Extra text shown under the headline (the free text of fuel / food notes).
    var detail: String? { kind == .generic || text.isEmpty ? nil : text }
}

extension TripNote {
    /// Missing keys get defaults, so notes saved by future / older versions still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? id
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? date
        kind = (try? c.decodeIfPresent(NoteKind.self, forKey: .kind)) ?? .generic
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        lat = try c.decodeIfPresent(Double.self, forKey: .lat)
        lon = try c.decodeIfPresent(Double.self, forKey: .lon)
        alt = try c.decodeIfPresent(Double.self, forKey: .alt)
        price = try c.decodeIfPresent(Double.self, forKey: .price)
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? ""
        amount = try c.decodeIfPresent(Double.self, forKey: .amount)
        fuelType = try c.decodeIfPresent(String.self, forKey: .fuelType) ?? ""
        food = try c.decodeIfPresent(String.self, forKey: .food) ?? ""
    }
}

// MARK: - Remembered input

/// Last-used currency and fuel type, so the next note is pre-filled.
enum NoteDefaults {
    private static let d = UserDefaults.standard

    static var currency: String {
        get { d.string(forKey: "note.currency") ?? Locale.current.currency?.identifier ?? "EUR" }
        set { d.set(newValue, forKey: "note.currency") }
    }

    static var fuelType: String {
        get { d.string(forKey: "note.fuelType") ?? "Petrol 95" }
        set { d.set(newValue, forKey: "note.fuelType") }
    }
}

// MARK: - Costs

/// Money and fuel totals of a set of notes. Amounts in different currencies are kept apart.
struct NoteCosts {
    var fuel: [String: Double] = [:]        // currency → total
    var food: [String: Double] = [:]
    var fuelAmount: [String: Double] = [:]  // unit ("L" / "kWh") → total

    init(_ notes: [TripNote]) {
        for n in notes {
            switch n.kind {
            case .fuel:
                if let p = n.price { fuel[n.currency, default: 0] += p }
                if let a = n.amount { fuelAmount[n.unit, default: 0] += a }
            case .food:
                if let p = n.price { food[n.currency, default: 0] += p }
            case .generic:
                break
            }
        }
    }

    var total: [String: Double] { fuel.merging(food, uniquingKeysWith: +) }
    var isEmpty: Bool { fuel.isEmpty && food.isEmpty && fuelAmount.isEmpty }

    /// "€75.10 + 450.00 NOK"
    static func text(_ sums: [String: Double]) -> String {
        sums.isEmpty ? "—" : sums.sorted { $0.key < $1.key }.map { Fmt.money($0.value, $0.key) }.joined(separator: " + ")
    }

    var fuelAmountText: String {
        fuelAmount.isEmpty ? "—"
            : fuelAmount.sorted { $0.key < $1.key }.map { "\(Fmt.decimal($0.value)) \($0.key)" }.joined(separator: " + ")
    }
}

// MARK: - Parsing / formatting

extension Fmt {
    /// "€75.10" for a known ISO currency code, otherwise "75.10 XYZ".
    static func money(_ v: Double, _ currency: String, decimals: Int = 2) -> String {
        let code = currency.trimmingCharacters(in: .whitespaces).uppercased()
        if code.count == 3 {
            return v.formatted(.currency(code: code).precision(.fractionLength(decimals)))
        }
        let n = String(format: "%.\(decimals)f", v)
        return code.isEmpty ? n : "\(n) \(currency)"
    }

    /// Up to 2 decimals, no trailing zeros: "42.3", "40".
    static func decimal(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...2)))
    }

    /// Parses "42,5" or "42.5" (either decimal separator).
    static func parseNumber(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, let v = Double(t), v.isFinite, v >= 0 else { return nil }
        return v
    }
}

// MARK: - Export

extension TripExport {

    /// All notes of the given trips, one row per note.
    static func notesCSV(_ trips: [Trip]) -> String {
        let cols = ["trip_date", "trip_type", "trip", "time_utc", "type", "lat", "lon", "alt_m",
                    "text", "food", "fuel_type", "amount", "unit", "price", "currency", "unit_price"]
        var out = cols.joined(separator: ",") + "\n"
        func n(_ v: Double?, _ dec: Int) -> String { v.map { String(format: "%.\(dec)f", $0) } ?? "" }
        for trip in trips.sorted(by: { $0.date < $1.date }) {
            for note in trip.tripNotes {
                let fuel = note.kind == .fuel
                let row: [String] = [
                    Fmt.day.string(from: trip.date), trip.kind.name, trip.title,
                    Fmt.iso.string(from: note.date), note.kind.name,
                    n(note.lat, 7), n(note.lon, 7), n(note.alt, 1),
                    note.text, note.kind == .food ? note.food : "",
                    fuel ? note.fuelType : "", fuel ? n(note.amount, 2) : "", fuel ? note.unit : "",
                    n(note.price, 2), note.price == nil ? "" : note.currency, fuel ? n(note.unitPrice, 3) : "",
                ]
                out += row.map(csvField).joined(separator: ",") + "\n"
            }
        }
        return out
    }

    /// GPX waypoints for notes that have a position.
    static func gpxWaypoints(_ trip: Trip) -> String {
        var out = ""
        for note in trip.tripNotes {
            guard let lat = note.lat, let lon = note.lon else { continue }
            out += String(format: "  <wpt lat=\"%.7f\" lon=\"%.7f\">", lat, lon)
            if let alt = note.alt { out += String(format: "<ele>%.1f</ele>", alt) }
            out += "<time>\(Fmt.iso.string(from: note.date))</time>"
            out += "<name>\(xml("\(note.kind.emoji) \(note.headline)"))</name>"
            if let d = note.detail { out += "<desc>\(xml(d))</desc>" }
            out += "<type>\(note.kind.name)</type></wpt>\n"
        }
        return out
    }
}
