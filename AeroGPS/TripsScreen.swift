import SwiftUI
import CoreLocation
import UIKit

/// Trips tab: record flights, list saved trips, overall statistics, export the logbook.
struct TripsScreen: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var sensors: SensorManager

    @State private var newTrip: Trip?
    @State private var editing: Trip?
    @State private var share: ShareItem?
    @State private var confirmStop = false
    @State private var pendingDelete: Trip?
    @State private var exporting = false

    private var finished: [Trip] { store.trips.filter { !$0.isRecording } }

    var body: some View {
        NavigationStack {
            List {
                recordingSection
                if !finished.isEmpty { totalsSection }
                tripsSection
            }
            .navigationTitle("Trips")
            .navigationDestination(for: UUID.self) { id in
                TripDetailView(tripID: id)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        exportAll()
                    } label: {
                        if exporting { ProgressView() } else { Image(systemName: "square.and.arrow.up") }
                    }
                    .disabled(store.trips.isEmpty || exporting)
                }
            }
            .sheet(item: $newTrip) { t in
                TripEditView(trip: t, mode: .new).environmentObject(store)
            }
            .sheet(item: $editing) { t in
                TripEditView(trip: t, mode: .edit).environmentObject(store)
            }
            .sheet(item: $share) { item in
                ShareSheet(items: item.urls)
            }
            .confirmationDialog("Stop recording this trip?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop recording", role: .destructive) { store.stopRecording() }
            }
            .confirmationDialog("Delete \(pendingDelete?.title ?? "trip")? Its track is removed permanently.",
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete trip", role: .destructive) {
                    if let t = pendingDelete { store.delete(t) }
                    pendingDelete = nil
                }
            }
            .alert("Error", isPresented: Binding(get: { store.lastError != nil },
                                                 set: { if !$0 { store.lastError = nil } })) {
                Button("OK") { store.lastError = nil }
            } message: {
                Text(store.lastError ?? "")
            }
        }
    }

    private func exportAll() {
        exporting = true
        Task {
            let urls = await store.exportAll()
            exporting = false
            if !urls.isEmpty { share = ShareItem(urls: urls) }
        }
    }

    // MARK: - Recording

    @ViewBuilder
    private var recordingSection: some View {
        if let t = store.activeTrip {
            Section {
                NavigationLink(value: t.id) {
                    RecordingCard(trip: t, location: sensors.location)
                }
                HStack {
                    Button {
                        editing = t
                    } label: {
                        Label("Edit details", systemImage: "square.and.pencil")
                    }
                    Spacer()
                    Button(role: .destructive) {
                        confirmStop = true
                    } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                    }
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Recording")
            }
        } else {
            Section {
                Button {
                    store.startRecording()
                } label: {
                    Label("Start recording now", systemImage: "record.circle")
                        .font(.headline)
                        .foregroundColor(.red)
                }
                Button {
                    newTrip = Trip()
                } label: {
                    Label("New trip with flight details…", systemImage: "airplane.departure")
                }
            } footer: {
                Text("Departure and arrival airports are detected from takeoff and landing. "
                     + "You can enter or correct them, and the flight number, at any time.")
            }
        }
    }

    // MARK: - Totals

    private var totalsSection: some View {
        let t = store.totals
        return Section("All trips") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    stat("Trips", "\(t.flights)")
                    stat("Air time", Fmt.duration(t.airTime))
                }
                GridRow {
                    stat("Distance", t.distance > 0 ? "\(Fmt.group(t.distance / 1000)) km" : "—")
                    stat("Airports", t.airports > 0 ? "\(t.airports) in \(t.countries) countr\(t.countries == 1 ? "y" : "ies")" : "—")
                }
                GridRow {
                    stat("Highest", t.maxAltitude.map { "\(Fmt.group($0 * 3.28084)) ft" } ?? "—")
                    stat("Fastest", t.maxSpeed > 0 ? "\(Fmt.group(t.maxSpeed * 1.943844)) kt" : "—")
                }
                if let l = t.longest {
                    GridRow {
                        stat("Longest", "\(l.route)  \(Fmt.duration(l.stats.airTime))")
                            .gridCellColumns(2)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Text(value).font(.system(.subheadline, design: .rounded).weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Trip list

    private var tripsSection: some View {
        Section("Trips") {
            if finished.isEmpty {
                Text("No trips yet. Start recording before takeoff (or any time in flight) — "
                     + "GPS works in Airplane Mode.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(finished) { t in
                NavigationLink(value: t.id) {
                    TripRow(trip: t)
                }
                .swipeActions {
                    Button {
                        pendingDelete = t
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)
                    Button {
                        editing = t
                    } label: {
                        Label("Edit", systemImage: "square.and.pencil")
                    }
                    .tint(.blue)
                }
            }
        }
    }
}

// MARK: - Rows

struct TripRow: View {
    let trip: Trip

    var body: some View {
        let s = trip.stats
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(trip.route).font(.system(.headline, design: .monospaced))
                if !trip.flightNumber.isEmpty {
                    Text(trip.flightNumber.uppercased()).font(.subheadline).foregroundColor(.secondary)
                }
                Spacer()
                Text(trip.date, style: .date).font(.caption).foregroundColor(.secondary)
            }
            let cities = [trip.fromAirport?.city, trip.toAirport?.city].map { $0 ?? "?" }
            if trip.fromAirport != nil || trip.toAirport != nil {
                Text(cities.joined(separator: " → ")).font(.subheadline).foregroundColor(.secondary)
            }
            HStack(spacing: 12) {
                Label(Fmt.duration(s.airTime ?? s.duration), systemImage: "clock")
                if s.distance > 0 { Label("\(Fmt.group(s.distance / 1000)) km", systemImage: "point.topleft.down.curvedto.point.bottomright.up") }
                if let a = s.maxAltitude { Label("\(Fmt.group(a * 3.28084)) ft", systemImage: "arrow.up") }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .labelStyle(CompactLabelStyle())
        }
        .padding(.vertical, 2)
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

/// Live summary of the trip being recorded.
struct RecordingCard: View {
    let trip: Trip
    let location: CLLocation?

    var body: some View {
        let s = trip.stats
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Circle().fill(Color.red).frame(width: 10, height: 10)
                        .opacity(Int(ctx.date.timeIntervalSince1970) % 2 == 0 ? 1 : 0.3)
                    Text(trip.title).font(.system(.headline, design: .monospaced))
                    Spacer()
                    Text(Fmt.duration(ctx.date.timeIntervalSince(trip.created))).monospacedDigit()
                }
                Text(phase(s)).font(.subheadline).foregroundColor(.secondary)
                if let l = location, ctx.date.timeIntervalSince(l.timestamp) < 10 {
                    HStack(spacing: 14) {
                        value("GS", l.speed >= 0 ? "\(Fmt.group(l.speed * 1.943844)) kt" : "—")
                        value("ALT", l.verticalAccuracy >= 0 ? "\(Fmt.group(l.altitude * 3.28084)) ft" : "—")
                        value("TRK", l.course >= 0 ? String(format: "%03.0f°", l.course) : "—")
                    }
                } else {
                    Text("No current GPS fix — hold the phone at the window")
                        .font(.caption).foregroundColor(.orange)
                }
                HStack(spacing: 14) {
                    value("max", s.maxSpeed > 0 ? "\(Fmt.group(s.maxSpeed * 1.943844)) kt" : "—")
                    value("max", s.maxAltitude.map { "\(Fmt.group($0 * 3.28084)) ft" } ?? "—")
                    value("dist", s.distance > 0 ? "\(Fmt.group(s.distance / 1000)) km" : "—")
                }
                Text("\(s.pointCount) fixes saved").font(.caption2).foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private func phase(_ s: TripStats) -> String {
        if let landing = s.landing {
            return "Landed \(Fmt.localTime(landing, trip.toAirport))" + (trip.to.isEmpty ? "" : " at \(trip.to)")
        }
        if let start = s.airborneStart {
            return s.takeoff != nil
                ? "Airborne since \(Fmt.localTime(start, trip.fromAirport))"
                : "Airborne (recording started in flight)"
        }
        if s.pointCount == 0 { return "Waiting for the first GPS fix…" }
        return trip.from.isEmpty ? "On the ground" : "On the ground at \(trip.from)"
    }

    private func value(_ label: String, _ v: String) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundColor(.secondary)
            Text(v).monospacedDigit()
        }
        .font(.system(size: 13, design: .monospaced))
    }
}

// MARK: - Edit / new trip

struct TripEditView: View {
    enum Mode { case new, edit }

    @EnvironmentObject private var store: TripStore
    @Environment(\.dismiss) private var dismiss
    @State private var trip: Trip
    let mode: Mode

    init(trip: Trip, mode: Mode) {
        _trip = State(initialValue: trip)
        self.mode = mode
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AirportField(title: "From", code: $trip.from)
                    AirportField(title: "To", code: $trip.to)
                } header: {
                    Text("Route")
                } footer: {
                    if mode == .new {
                        Text("Leave empty to detect the airports from takeoff and landing.")
                    }
                }
                Section("Flight") {
                    TextField("Flight number, e.g. DY604", text: $trip.flightNumber)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Airline", text: $trip.airline)
                    TextField("Aircraft, e.g. Boeing 737-800", text: $trip.aircraft)
                        .autocorrectionDisabled()
                    TextField("Seat", text: $trip.seat)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
                Section("Notes") {
                    TextField("Notes", text: $trip.notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(mode == .new ? "New trip" : "Trip details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode == .new ? "Start recording" : "Save") {
                        save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func save() {
        var t = trip
        let clean = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        t.from = clean(t.from).uppercased()
        t.to = clean(t.to).uppercased()
        t.flightNumber = clean(t.flightNumber).uppercased().replacingOccurrences(of: " ", with: "")
        t.airline = clean(t.airline)
        t.aircraft = clean(t.aircraft)
        t.seat = clean(t.seat).uppercased()
        t.notes = clean(t.notes)
        // Store IATA when the user typed an ICAO code.
        if let a = Airports.shared.find(t.from) { t.from = a.iata }
        if let a = Airports.shared.find(t.to) { t.to = a.iata }
        switch mode {
        case .new:  store.startRecording(t)
        case .edit: store.updateDetails(t)
        }
    }
}

/// Text field for an airport code with the airport's name below and search suggestions (code, city or name).
struct AirportField: View {
    let title: String
    @Binding var code: String
    @FocusState private var focused: Bool

    var body: some View {
        let match = Airports.shared.find(code)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).foregroundColor(.secondary).frame(width: 44, alignment: .leading)
                TextField("Code or city", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .font(.system(.body, design: .monospaced))
                if !code.isEmpty && focused {
                    Button { code = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let a = match {
                Text(a.title).font(.caption).foregroundColor(.secondary)
            } else if focused && code.count >= 2 {
                let results = Airports.shared.search(code)
                if results.isEmpty {
                    Text("No airport found").font(.caption).foregroundColor(.orange)
                }
                ForEach(results, id: \.iata) { a in
                    Button {
                        code = a.iata
                        focused = false
                    } label: {
                        HStack(spacing: 8) {
                            Text(a.iata).font(.system(.subheadline, design: .monospaced).weight(.bold))
                            Text(a.title).font(.caption).lineLimit(1).foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.borderless)
                }
            } else if !code.isEmpty {
                Text("Unknown airport code").font(.caption).foregroundColor(.orange)
            }
        }
    }
}

// MARK: - Sharing

struct ShareItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
