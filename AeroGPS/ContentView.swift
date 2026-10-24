import SwiftUI
import CoreLocation

struct ContentView: View {
    @EnvironmentObject private var s: SensorManager
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 8) {
            statusBar
            gpsCard
            HStack(spacing: 8) {
                accelCard
                compassCard
            }
            logPanel
            controls
        }
        .padding(8)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    // MARK: - Status

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text("Location: \(s.authName)")
            Spacer()
            Text("fixes: \(s.fixCount)")
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }

    private var statusColor: Color {
        switch s.authStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return s.location == nil ? .yellow : .green
        case .denied, .restricted:
            return .red
        default:
            return .gray
        }
    }

    // MARK: - GPS

    private var gpsCard: some View {
        card("GPS") {
            let l = s.location
            row("lat",   l.map { fmt($0.coordinate.latitude, 7) })
            row("lon",   l.map { fmt($0.coordinate.longitude, 7) })
            row("alt",   l.map { "\(fmt($0.altitude)) m  (ell \(fmt($0.ellipsoidalAltitude)) m)" })
            row("acc",   l.map { "h \(fmt($0.horizontalAccuracy)) m   v \(fmt($0.verticalAccuracy)) m" })
            row("speed", l.map { "\(fmt($0.speed, 2)) m/s   \(fmt($0.speed * 3.6)) km/h   \(fmt($0.speed * 1.943844)) kn" })
            row("course", l.map { "\(fmt($0.course))°  ±\(fmt($0.courseAccuracy))°" })
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                row("fix age", l.map { "\(fmt(ctx.date.timeIntervalSince($0.timestamp), 1)) s" })
            }
        }
    }

    // MARK: - Accelerometer

    private var accelCard: some View {
        card("Accel (g)") {
            let a = s.accel
            let mag = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            row("x", fmt(a.x, 3))
            row("y", fmt(a.y, 3))
            row("z", fmt(a.z, 3))
            row("|a|", fmt(mag, 3))
        }
    }

    // MARK: - Compass

    private var compassCard: some View {
        card("Compass") {
            let h = s.heading
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                    Text("N")
                        .font(.system(size: 9, weight: .bold))
                        .offset(y: -22)
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.red)
                        .rotationEffect(.degrees(-(h?.magneticHeading ?? 0)))
                }
                .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 2) {
                    row("mag",  h.map { "\(fmt($0.magneticHeading))°" })
                    row("true", h.map { $0.trueHeading >= 0 ? "\(fmt($0.trueHeading))°" : "n/a" })
                    row("±",    h.map { "\(fmt($0.headingAccuracy))°" })
                }
            }
        }
    }

    // MARK: - Log

    private var logPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(s.log) { line in
                        Text(line.text)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(lineColor(line.text))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(line.id)
                    }
                }
                .padding(6)
            }
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(10)
            .onChange(of: s.log.count) { _ in
                guard autoScroll, let last = s.log.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func lineColor(_ text: String) -> Color {
        // Skip the "HH:mm:ss.SSS " prefix.
        let body = text.dropFirst(13)
        if body.hasPrefix("ERR") || body.hasPrefix("WARN") || body.hasPrefix("GAP") { return .red }
        if body.hasPrefix("$GP")  { return .blue }
        if body.hasPrefix("HDG")  { return .green }
        if body.hasPrefix("AUTH") || body.hasPrefix("APP") { return .orange }
        return .primary
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Button(s.isPaused ? "Resume" : "Pause") { s.isPaused.toggle() }
            Button("Clear") { s.clearLog() }
            Toggle("NMEA", isOn: $s.emitNMEA)
                .toggleStyle(.button)
            Toggle("Scroll", isOn: $autoScroll)
                .toggleStyle(.button)
            Spacer()
            ShareLink(item: s.logText) {
                Image(systemName: "square.and.arrow.up")
            }
        }
        .font(.caption)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: - Helpers

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.bold())
                .foregroundColor(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(10)
    }

    private func row(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)
            Text(value ?? "—")
                .monospacedDigit()
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private func fmt(_ v: Double, _ decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f", v)
    }
}
