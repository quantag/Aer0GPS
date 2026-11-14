import SwiftUI
import Charts
import CoreLocation

/// One trip: route map, altitude / speed profile, statistics, details, export.
struct TripDetailView: View {
    let tripID: UUID

    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var sensors: SensorManager
    @Environment(\.dismiss) private var dismiss

    @State private var points: [TripPoint] = []
    @State private var loading = true
    @State private var editing: Trip?
    @State private var share: ShareItem?
    @State private var fullMap = false
    @State private var profile = Profile.altitude
    @State private var confirmDelete = false
    @State private var confirmRedetect = false

    enum Profile: String, CaseIterable { case altitude = "Altitude", speed = "Speed" }

    private var trip: Trip? { store.trips.first { $0.id == tripID } }

    var body: some View {
        if let trip {
            content(trip)
        } else {
            Text("This trip was deleted.").foregroundColor(.secondary)
        }
    }

    private func content(_ trip: Trip) -> some View {
        let pts = trip.isRecording ? store.activePoints : points
        let track = pts.filter(\.hasGoodPosition).map(\.mercator)
        let live = trip.isRecording ? sensors.location : nil

        return List {
            Section {
                TripMapView(track: track, from: trip.fromAirport, to: trip.toAirport, live: live, showsCities: false)
                    .frame(height: 300)
                    .overlay(alignment: .topTrailing) {
                        Button { fullMap = true } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right.circle.fill")
                                .font(.system(size: 28))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.white, Color.black.opacity(0.45))
                        }
                        .padding(8)
                    }
                    .overlay {
                        if loading && !trip.isRecording { ProgressView().tint(.white) }
                    }
                    .listRowInsets(EdgeInsets())
            }

            routeSection(trip)
            statsSection(trip)
            profileSection(pts)
            detailsSection(trip)

            Section {
                Button {
                    confirmRedetect = true
                } label: {
                    Label("Detect airports from track", systemImage: "location.magnifyingglass")
                }
                .disabled(trip.stats.pointCount == 0)
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete trip", systemImage: "trash")
                }
            }
        }
        .navigationTitle(trip.route)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Menu {
                    Button("GPX track") { export(trip, [.gpx]) }
                    Button("CSV — every fix") { export(trip, [.csv]) }
                    Button("Summary (text)") { export(trip, [.summary]) }
                    Button("All three") { export(trip, [.gpx, .csv, .summary]) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                Button("Edit") { editing = trip }
            }
        }
        .task(id: "\(trip.id)-\(trip.isRecording)") {
            guard !trip.isRecording else { loading = false; return }
            loading = true
            points = await store.points(for: trip)
            loading = false
        }
        .sheet(item: $editing) { t in
            TripEditView(trip: t, mode: .edit).environmentObject(store)
        }
        .sheet(item: $share) { item in
            ShareSheet(items: item.urls)
        }
        .fullScreenCover(isPresented: $fullMap) {
            ZStack(alignment: .topLeading) {
                TripMapView(track: track, from: trip.fromAirport, to: trip.toAirport, live: live)
                    .ignoresSafeArea()
                Button { fullMap = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 42, height: 42)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                .foregroundColor(.primary)
                .padding(12)
            }
        }
        .confirmationDialog("Delete this trip? Its track is removed permanently.",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete trip", role: .destructive) {
                store.delete(trip)
                dismiss()
            }
        }
        .confirmationDialog("Replace From / To with the airports nearest to the recorded takeoff and landing?",
                            isPresented: $confirmRedetect, titleVisibility: .visible) {
            Button("Detect airports") {
                Task { await store.redetect(trip) }
            }
        }
    }

    private func export(_ trip: Trip, _ kinds: [TripStore.ExportKind]) {
        Task {
            let urls = await store.exportFiles(trip, kinds: kinds)
            if !urls.isEmpty { share = ShareItem(urls: urls) }
        }
    }

    // MARK: - Sections

    private func routeSection(_ trip: Trip) -> some View {
        let s = trip.stats
        return Section {
            airportRow("From", trip.from, trip.fromAirport, auto: trip.autoFrom,
                       time: s.takeoff.map { "Takeoff \(Fmt.localTime($0, trip.fromAirport))" })
            airportRow("To", trip.to, trip.toAirport, auto: trip.autoTo,
                       time: s.landing.map { "Landing \(Fmt.localTime($0, trip.toAirport))" })
        } header: {
            Text(trip.stats.firstFix.map { Fmt.dateTime.string(from: $0) } ?? Fmt.dateTime.string(from: trip.created))
        }
    }

    private func airportRow(_ label: String, _ code: String, _ airport: Airport?, auto: Bool, time: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(code.isEmpty ? "???" : code)
                .font(.system(.title2, design: .monospaced).weight(.bold))
                .frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if let a = airport {
                    Text(a.name).font(.subheadline)
                    Text("\(a.city), \(a.country)").font(.caption).foregroundColor(.secondary)
                } else {
                    Text(code.isEmpty ? "\(label): not known yet" : "Unknown code")
                        .font(.subheadline).foregroundColor(.secondary)
                }
                if let time { Text(time).font(.caption).monospacedDigit() }
                if auto { Text("detected from track").font(.caption2).foregroundColor(.blue) }
            }
        }
        .padding(.vertical, 2)
    }

    private func statsSection(_ trip: Trip) -> some View {
        let s = trip.stats
        var air = Fmt.duration(s.airTime)
        if s.airTime != nil && (s.startedAirborne || s.endedAirborne) { air += "  (partial)" }
        return Section("Statistics") {
            row("Flight time", air)
            row("Recorded", Fmt.duration(s.duration))
            row("Distance flown", Fmt.distance(s.distance))
            if let r = trip.routeDistance { row("Route (great circle)", Fmt.distance(r)) }
            row("Max ground speed", Fmt.speed(s.maxSpeed))
            if let at = s.airTime, at > 60, s.distance > 0 {
                row("Avg ground speed", Fmt.speed(s.distance / at))
            }
            row("Max altitude", Fmt.altitude(s.maxAltitude))
            row("Max climb", Fmt.vspeed(s.maxClimb))
            row("Max descent", Fmt.vspeed(s.maxDescent))
            row("GPS fixes", "\(s.pointCount)")
            row("Longest GPS gap", s.pointCount > 1 ? Fmt.duration(s.longestGap) : "—")
        }
    }

    @ViewBuilder
    private func profileSection(_ pts: [TripPoint]) -> some View {
        if pts.count > 2 {
            Section {
                Picker("Profile", selection: $profile) {
                    ForEach(Profile.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                ProfileChart(points: pts, profile: profile)
                    .frame(height: 170)
            }
        }
    }

    private func detailsSection(_ trip: Trip) -> some View {
        Section("Details") {
            row("Flight", trip.flightNumber.isEmpty ? "—" : trip.flightNumber)
            row("Airline", trip.airline.isEmpty ? "—" : trip.airline)
            row("Aircraft", trip.aircraft.isEmpty ? "—" : trip.aircraft)
            row("Seat", trip.seat.isEmpty ? "—" : trip.seat)
            if !trip.notes.isEmpty {
                Text(trip.notes).font(.subheadline)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundColor(.secondary).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

/// Altitude (ft) or ground speed (kt) over time, downsampled to ~400 points.
struct ProfileChart: View {
    let points: [TripPoint]
    let profile: TripDetailView.Profile

    private struct Sample: Identifiable {
        let id: Int
        let date: Date
        let value: Double
    }

    var body: some View {
        let samples = Self.samples(points, profile)
        if samples.count < 2 {
            Text("Not enough valid data").font(.caption).foregroundColor(.secondary)
        } else {
            Chart(samples) { s in
                AreaMark(x: .value("Time", s.date), y: .value(profile.rawValue, s.value))
                    .foregroundStyle(LinearGradient(colors: [Color.blue.opacity(0.35), Color.blue.opacity(0.05)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", s.date), y: .value(profile.rawValue, s.value))
                    .foregroundStyle(Color.blue)
            }
            .chartYAxisLabel(profile == .altitude ? "ft" : "kt")
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
        }
    }

    private static func samples(_ pts: [TripPoint], _ profile: TripDetailView.Profile) -> [Sample] {
        let valid: [TripPoint]
        switch profile {
        case .altitude: valid = pts.filter(\.hasGoodAltitude)
        case .speed:    valid = pts.filter { $0.spd >= 0 && $0.spd < 400 }
        }
        let step = max(1, valid.count / 400)
        return stride(from: 0, to: valid.count, by: step).map { i in
            let p = valid[i]
            let v = profile == .altitude ? Double(p.alt) * 3.28084 : Double(p.spd) * 1.943844
            return Sample(id: i, date: p.date, value: v)
        }
    }
}
