import Foundation
import CoreLocation
import UIKit

/// Saves trips and records the active one.
///
/// On disk (Application Support/Trips/<uuid>/):
///  - trip.json   — details and cached statistics (`Trip`)
///  - points.csv  — one line per fix, appended while recording (see `TripPoint.csvLine`)
///
/// Points are appended every few seconds, so at most a few seconds are lost if the app is killed.
/// A trip that was still recording when the app was killed keeps recording after relaunch.
@MainActor
final class TripStore: ObservableObject {

    /// Newest first.
    @Published private(set) var trips: [Trip] = []
    /// Points of the trip being recorded (kept in memory for live stats and the map).
    @Published private(set) var activePoints: [TripPoint] = []
    @Published var lastError: String?

    var activeTrip: Trip? { trips.first(where: \.isRecording) }

    private let root: URL
    private var pending: [TripPoint] = []
    private var lastFlush = Date()
    private var lastStatsUpdate = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("Trips", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()

        let nc = NotificationCenter.default
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            })
        }
    }

    // MARK: - Paths

    private func dir(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func metaURL(_ id: UUID) -> URL { dir(id).appendingPathComponent("trip.json") }
    private func pointsURL(_ id: UUID) -> URL { dir(id).appendingPathComponent("points.csv") }

    // MARK: - Load / save

    private func load() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Trip] = []
        for d in dirs {
            guard let data = try? Data(contentsOf: d.appendingPathComponent("trip.json")),
                  let trip = try? decoder.decode(Trip.self, from: data) else { continue }
            loaded.append(trip)
        }
        trips = loaded.sorted { $0.date > $1.date }

        // Only one trip can record; resume it (the app was killed or crashed mid-flight).
        let recording = trips.indices.filter { trips[$0].isRecording }
        for i in recording.dropFirst() {
            trips[i].isRecording = false
            save(trips[i])
        }
        if let i = recording.first {
            activePoints = readPoints(trips[i].id)
        }
    }

    private func save(_ trip: Trip) {
        do {
            try FileManager.default.createDirectory(at: dir(trip.id), withIntermediateDirectories: true)
            try encoder.encode(trip).write(to: metaURL(trip.id), options: .atomic)
        } catch {
            lastError = "Could not save trip: \(error.localizedDescription)"
        }
    }

    private func readPoints(_ id: UUID) -> [TripPoint] {
        guard let text = try? String(contentsOf: pointsURL(id), encoding: .utf8) else { return [] }
        return TripPoint.parse(text)
    }

    /// Points of a trip, read off the main thread (the active trip comes from memory).
    func points(for trip: Trip) async -> [TripPoint] {
        if trip.isRecording { return activePoints }
        let url = pointsURL(trip.id)
        return await Task.detached(priority: .userInitiated) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [TripPoint]() }
            return TripPoint.parse(text)
        }.value
    }

    // MARK: - Recording

    /// Starts a new trip with the given details (all optional; they can be filled in later).
    func startRecording(_ details: Trip = Trip()) {
        if activeTrip != nil { stopRecording() }
        var t = details
        t.id = UUID()
        t.created = Date()
        t.isRecording = true
        t.stats = TripStats()
        activePoints = []
        pending = []
        lastFlush = Date()
        lastStatsUpdate = .distantPast
        save(t)
        FileManager.default.createFile(atPath: pointsURL(t.id).path, contents: nil)
        trips.insert(t, at: 0)
    }

    func stopRecording() {
        guard let i = trips.firstIndex(where: \.isRecording) else { return }
        flush()
        trips[i].isRecording = false
        trips[i].stats = TripStats.compute(activePoints)
        trips[i].autoDetectAirports()
        save(trips[i])
        activePoints = []
        sortTrips()
    }

    /// Called for every CoreLocation fix. Keeps at most one point per second.
    func ingest(_ l: CLLocation) {
        guard let i = trips.firstIndex(where: \.isRecording) else { return }
        let now = Date()
        // Skip invalid and cached/stale fixes (iOS replays old fixes after a restart).
        guard l.horizontalAccuracy >= 0, now.timeIntervalSince(l.timestamp) < 10 else { return }
        let p = TripPoint(l)
        if let last = activePoints.last, p.t - last.t < 0.9 { return }
        activePoints.append(p)
        pending.append(p)
        if pending.count >= 30 || now.timeIntervalSince(lastFlush) >= 10 { flush() }
        if now.timeIntervalSince(lastStatsUpdate) >= 5 {
            lastStatsUpdate = now
            trips[i].stats = TripStats.compute(activePoints)
            trips[i].autoDetectAirports()
            save(trips[i])
        }
    }

    /// Appends buffered points to the active trip's points.csv.
    func flush() {
        guard !pending.isEmpty, let trip = activeTrip else { return }
        let url = pointsURL(trip.id)
        let data = Data((pending.map(\.csvLine).joined(separator: "\n") + "\n").utf8)
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: dir(trip.id), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: data)
            pending.removeAll()
            lastFlush = Date()
        } catch {
            lastError = "Could not write track: \(error.localizedDescription)"
            if pending.count > 3600 { pending.removeFirst(pending.count - 3600) }   // don't grow forever
        }
    }

    // MARK: - Editing

    /// Saves the user-editable fields (statistics stay as recorded).
    func updateDetails(_ edited: Trip) {
        guard let i = trips.firstIndex(where: { $0.id == edited.id }) else { return }
        var t = trips[i]
        if t.from != edited.from { t.autoFrom = false }
        if t.to != edited.to { t.autoTo = false }
        t.from = edited.from
        t.to = edited.to
        t.flightNumber = edited.flightNumber
        t.airline = edited.airline
        t.aircraft = edited.aircraft
        t.seat = edited.seat
        t.notes = edited.notes
        trips[i] = t
        save(t)
    }

    /// Re-reads the track, recomputes statistics and re-detects both airports (replacing typed codes).
    func redetect(_ trip: Trip) async {
        let pts = await points(for: trip)
        guard let i = trips.firstIndex(where: { $0.id == trip.id }) else { return }
        trips[i].stats = TripStats.compute(pts)
        trips[i].autoDetectAirports(overwrite: true)
        save(trips[i])
    }

    func delete(_ trip: Trip) {
        if trip.isRecording {
            pending.removeAll()
            activePoints = []
        }
        try? FileManager.default.removeItem(at: dir(trip.id))
        trips.removeAll { $0.id == trip.id }
    }

    private func sortTrips() {
        trips.sort { $0.date > $1.date }
    }

    // MARK: - Export

    enum ExportKind { case gpx, csv, summary }

    /// Writes export files for one trip to a temporary folder and returns their URLs.
    func exportFiles(_ trip: Trip, kinds: [ExportKind]) async -> [URL] {
        let pts = await points(for: trip)
        var files: [URL?] = []
        for k in kinds {
            switch k {
            case .gpx:     files.append(writeExport("\(trip.fileName).gpx", TripExport.gpx([(trip, pts)])))
            case .csv:     files.append(writeExport("\(trip.fileName).csv", TripExport.pointsCSV(pts)))
            case .summary: files.append(writeExport("\(trip.fileName).txt", TripExport.summary(trip)))
            }
        }
        return files.compactMap { $0 }
    }

    /// Logbook CSV (one row per flight) plus one GPX with every track.
    func exportAll() async -> [URL] {
        var all: [(Trip, [TripPoint])] = []
        for t in trips.sorted(by: { $0.date < $1.date }) {
            all.append((t, await points(for: t)))
        }
        let stamp = Fmt.day.string(from: Date())
        return [
            writeExport("AeroGPS logbook \(stamp).csv", TripExport.logbookCSV(trips)),
            writeExport("AeroGPS all tracks \(stamp).gpx", TripExport.gpx(all)),
        ].compactMap { $0 }
    }

    private func writeExport(_ name: String, _ text: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Export", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            lastError = "Export failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Totals

    struct Totals {
        var flights = 0
        var airTime: TimeInterval = 0
        var distance: Double = 0
        var maxAltitude: Double?
        var maxSpeed: Double = 0
        var longest: Trip?
        var airports = 0
        var countries = 0
    }

    var totals: Totals {
        var t = Totals()
        var airports = Set<String>(), countries = Set<String>()
        for trip in trips {
            let s = trip.stats
            t.flights += 1
            t.airTime += s.airTime ?? 0
            t.distance += s.distance
            if let a = s.maxAltitude { t.maxAltitude = max(t.maxAltitude ?? a, a) }
            t.maxSpeed = max(t.maxSpeed, s.maxSpeed)
            if (s.airTime ?? 0) > (t.longest?.stats.airTime ?? 0) { t.longest = trip }
            for a in [trip.fromAirport, trip.toAirport].compactMap({ $0 }) {
                airports.insert(a.iata)
                countries.insert(a.country)
            }
        }
        t.airports = airports.count
        t.countries = countries.count
        return t
    }
}
