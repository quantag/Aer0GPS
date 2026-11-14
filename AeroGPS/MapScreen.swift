import SwiftUI
import CoreLocation

/// Offline map tab: Natural Earth coastlines/borders/cities drawn with Canvas,
/// with current GPS position, accuracy circle, direction arrow and flown track.
struct MapScreen: View {
    @EnvironmentObject private var s: SensorManager

    // Map camera, in mercator unit space.
    @State private var center = Mercator.project(lat: 50, lon: 10)
    @State private var zoom: Double = 4
    @State private var follow = true
    @State private var dragStart: SIMD2<Double>?
    @State private var pinchStartZoom: Double?
    @State private var showCities = true

    private let world = WorldMap.shared
    private let minZoom = 1.0, maxZoom = 15.0

    var body: some View {
        // Capture published values once so the Canvas closure doesn't touch the main actor.
        let loc = s.location
        let heading = s.heading
        let track = s.track
        let cam = cameraCenter(loc)

        GeometryReader { geo in
            ZStack {
                Canvas { ctx, size in
                    let r = MapRenderer(ctx: ctx, size: size, center: cam, zoom: zoom)
                    r.drawBase(world, showCities: showCities)
                    r.drawTrack(track)
                    if let loc { r.drawPosition(loc, heading: heading) }
                    r.drawScaleBar()
                }
                .gesture(dragGesture(width: geo.size.width, cam: cam))
                .simultaneousGesture(pinchGesture)
                .onTapGesture(count: 2) { zoom = min(maxZoom, zoom + 1) }

                controls(loc)
            }
        }
        .background(MapRenderer.ocean)
    }

    private func cameraCenter(_ loc: CLLocation?) -> SIMD2<Double> {
        if follow, let loc { return Mercator.project(loc.coordinate) }
        return center
    }

    // MARK: - Gestures

    private func dragGesture(width: CGFloat, cam: SIMD2<Double>) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                if dragStart == nil {
                    dragStart = cam
                    follow = false
                }
                let scale = MapRenderer.pixelsPerUnit(zoom)
                var c = dragStart! - SIMD2(Double(g.translation.width), Double(g.translation.height)) / scale
                c.x = c.x - floor(c.x)                    // wrap around the dateline
                c.y = min(max(c.y, 0), 1)
                center = c
            }
            .onEnded { _ in dragStart = nil }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { v in
                if pinchStartZoom == nil { pinchStartZoom = zoom }
                zoom = min(max(pinchStartZoom! + log2(Double(v)), minZoom), maxZoom)
            }
            .onEnded { _ in pinchStartZoom = nil }
    }

    // MARK: - Overlay UI

    @ViewBuilder
    private func controls(_ loc: CLLocation?) -> some View {
        VStack {
            infoPanel(loc)
            Spacer()
            HStack(alignment: .bottom) {
                Text("Map data: Natural Earth")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.leading, 8)
                    .padding(.bottom, 34)
                Spacer()
                VStack(spacing: 10) {
                    mapButton(showCities ? "building.2.fill" : "building.2") { showCities.toggle() }
                    mapButton("plus") { zoom = min(maxZoom, zoom + 1) }
                    mapButton("minus") { zoom = max(minZoom, zoom - 1) }
                    mapButton(follow ? "location.fill" : "location") {
                        follow = true
                        if loc != nil && zoom < 8 { zoom = 8 }
                    }
                    mapButton("trash") { s.clearTrack() }
                }
                .padding(10)
            }
        }
    }

    private func infoPanel(_ loc: CLLocation?) -> some View {
        Group {
            if let error = world.loadError {
                Text(error).foregroundColor(.red)
            } else if let l = loc {
                let kt = l.speed >= 0 ? l.speed * 1.943844 : -1
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%@  %@", Self.dms(l.coordinate.latitude, pos: "N", neg: "S"),
                                Self.dms(l.coordinate.longitude, pos: "E", neg: "W")))
                    Text(String(format: "GS %@   TRK %@   ALT %@",
                                kt >= 0 ? String(format: "%.0f kt (%.0f km/h)", kt, l.speed * 3.6) : "—",
                                l.course >= 0 ? String(format: "%03.0f°", l.course) : "—",
                                l.verticalAccuracy >= 0
                                    ? String(format: "%.0f ft (%.0f m)", l.altitude * 3.28084, l.altitude) : "—"))
                    Text(String(format: "±%.0f m   fix %.0f s ago   track %d pts",
                                l.horizontalAccuracy, Date().timeIntervalSince(l.timestamp), s.track.count))
                        .foregroundColor(.white.opacity(0.7))
                }
            } else {
                Text("Waiting for GPS fix… (hold the phone at the window)")
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundColor(.white)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.55))
        .cornerRadius(10)
        .padding(8)
    }

    private func mapButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 42, height: 42)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
        .foregroundColor(.primary)
    }

    static func dms(_ v: Double, pos: String, neg: String) -> String {
        let a = abs(v)
        let d = Int(a)
        let m = (a - Double(d)) * 60
        return String(format: "%d°%06.3f'%@", d, m, v >= 0 ? pos : neg)
    }
}

// MARK: - Renderer

/// Draws the offline map into a SwiftUI Canvas. Shared by the Map tab and trip maps.
struct MapRenderer {
    static let ocean = Color(red: 0.09, green: 0.20, blue: 0.36)
    static let land = Color(red: 0.20, green: 0.31, blue: 0.24)
    static let lake = Color(red: 0.11, green: 0.24, blue: 0.42)
    static let border = Color(white: 1, opacity: 0.35)
    static let grid = Color(white: 1, opacity: 0.12)
    static let trackColor = Color(red: 1.0, green: 0.80, blue: 0.20)

    static func pixelsPerUnit(_ zoom: Double) -> Double { 256 * pow(2, zoom) }

    let ctx: GraphicsContext
    let size: CGSize
    let center: SIMD2<Double>
    let zoom: Double
    let scale: Double
    // Visible rectangle in mercator units (x not wrapped).
    let minX: Double, maxX: Double, minY: Double, maxY: Double

    init(ctx: GraphicsContext, size: CGSize, center: SIMD2<Double>, zoom: Double) {
        self.ctx = ctx
        self.size = size
        self.center = center
        self.zoom = zoom
        scale = Self.pixelsPerUnit(zoom)
        let hw = Double(size.width) / 2 / scale, hh = Double(size.height) / 2 / scale
        minX = center.x - hw; maxX = center.x + hw
        minY = center.y - hh; maxY = center.y + hh
    }

    /// World copies (integer x offsets) that intersect the screen.
    private var copies: ClosedRange<Int> { Int(floor(minX))...Int(floor(maxX)) }

    private func screen(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: (x - center.x) * scale + Double(size.width) / 2,
                y: (y - center.y) * scale + Double(size.height) / 2)
    }

    /// Screen position of a mercator point, using the world copy nearest the camera.
    private func screenNearest(_ p: SIMD2<Double>) -> CGPoint {
        var x = p.x
        x += (center.x - x).rounded()
        return screen(x, p.y)
    }

    // MARK: Base map

    func drawBase(_ world: WorldMap, showCities: Bool) {
        let coarse = zoom < 5.5
        let land = buildPath(coarse ? world.landCoarse : world.landFull, closed: true)
        ctx.fill(land, with: .color(Self.land), style: FillStyle(eoFill: true))
        let lakes = buildPath(coarse ? world.lakesCoarse : world.lakesFull, closed: true)
        ctx.fill(lakes, with: .color(Self.lake), style: FillStyle(eoFill: true))
        drawGraticule()
        let borders = buildPath(coarse ? world.bordersCoarse : world.bordersFull, closed: false)
        ctx.stroke(borders, with: .color(Self.border), lineWidth: 0.8)
        if showCities { drawCities(world.cities) }
    }

    /// One combined path of all visible shapes, skipping points closer than ~0.7 px.
    private func buildPath(_ shapes: [MapShape], closed: Bool) -> Path {
        var path = Path()
        let minStep = 0.7 / scale
        for k in copies {
            let dx = Double(k)
            for shape in shapes {
                if Double(shape.maxX) + dx < minX || Double(shape.minX) + dx > maxX
                    || Double(shape.maxY) < minY || Double(shape.minY) > maxY { continue }
                for ring in shape.rings where ring.count > 1 {
                    var lastX = Double(ring[0].x) + dx, lastY = Double(ring[0].y)
                    path.move(to: screen(lastX, lastY))
                    for i in 1..<ring.count {
                        let x = Double(ring[i].x) + dx, y = Double(ring[i].y)
                        if abs(x - lastX) < minStep && abs(y - lastY) < minStep && i != ring.count - 1 { continue }
                        path.addLine(to: screen(x, y))
                        lastX = x; lastY = y
                    }
                    if closed { path.closeSubpath() }
                }
            }
        }
        return path
    }

    // MARK: Lat/lon grid

    private func drawGraticule() {
        let pxPerDeg = scale / 360
        let steps: [Double] = [0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30]
        let step = steps.first { $0 * pxPerDeg >= 90 } ?? 30
        var lines = Path()
        var labels: [(String, CGPoint, UnitPoint)] = []

        // Meridians
        let lonMin = minX * 360 - 180, lonMax = maxX * 360 - 180
        var lon = (lonMin / step).rounded(.up) * step
        while lon <= lonMax {
            let x = screen((lon + 180) / 360, 0).x
            lines.move(to: CGPoint(x: x, y: 0))
            lines.addLine(to: CGPoint(x: x, y: size.height))
            var norm = lon.truncatingRemainder(dividingBy: 360)
            if norm > 180 { norm -= 360 }
            if norm < -180 { norm += 360 }
            labels.append((Self.degLabel(norm, step: step, pos: "E", neg: "W"),
                           CGPoint(x: x + 3, y: size.height - 96), .bottomLeading))
            lon += step
        }

        // Parallels
        let latTop = Mercator.latitude(y: max(minY, 0)), latBottom = Mercator.latitude(y: min(maxY, 1))
        var lat = (latBottom / step).rounded(.up) * step
        while lat <= latTop {
            if abs(lat) <= 85 {
                let y = screen(0, Mercator.project(lat: lat, lon: 0).y).y
                lines.move(to: CGPoint(x: 0, y: y))
                lines.addLine(to: CGPoint(x: size.width, y: y))
                labels.append((Self.degLabel(lat, step: step, pos: "N", neg: "S"),
                               CGPoint(x: 4, y: y - 2), .bottomLeading))
            }
            lat += step
        }

        ctx.stroke(lines, with: .color(Self.grid), lineWidth: 1)
        for (text, p, anchor) in labels {
            ctx.draw(Text(text).font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.45)),
                     at: p, anchor: anchor)
        }
    }

    private static func degLabel(_ v: Double, step: Double, pos: String, neg: String) -> String {
        let decimals = step < 0.1 ? 2 : (step < 1 ? 1 : 0)
        let h = v > 0 ? pos : (v < 0 ? neg : "")
        return String(format: "%.\(decimals)f°%@", abs(v), h)
    }

    // MARK: Cities

    private func drawCities(_ cities: [MapCity]) {
        // Show more (smaller) places as you zoom in; cities are pre-sorted by importance.
        let maxRank = Int(zoom * 1.4 - 2)
        guard maxRank >= 0 else { return }
        var placed: [CGRect] = []
        var dots = Path()
        for c in cities where c.rank <= maxRank {
            for k in copies {
                let x = Double(c.point.x) + Double(k), y = Double(c.point.y)
                guard x >= minX, x <= maxX, y >= minY, y <= maxY else { continue }
                let p = screen(x, y)
                let resolved = ctx.resolve(Text(c.name).font(.system(size: 10)).foregroundColor(.white.opacity(0.8)))
                let ts = resolved.measure(in: CGSize(width: 300, height: 50))
                let rect = CGRect(x: p.x + 4, y: p.y - ts.height / 2, width: ts.width, height: ts.height)
                if placed.contains(where: { $0.intersects(rect.insetBy(dx: -3, dy: -2)) }) { continue }
                placed.append(rect)
                dots.addEllipse(in: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4))
                ctx.draw(resolved, in: rect)
            }
            if placed.count > 120 { break }
        }
        ctx.fill(dots, with: .color(.white.opacity(0.8)))
    }

    // MARK: Track and position

    func drawTrack(_ track: [SIMD2<Double>], color: Color = MapRenderer.trackColor, width: CGFloat = 2.5) {
        guard track.count > 1 else { return }
        var path = Path()
        var last = screenNearest(track[0])
        path.move(to: last)
        for i in 1..<track.count {
            let p = screenNearest(track[i])
            if abs(p.x - last.x) > size.width {           // crossed the dateline: break the line
                path.move(to: p)
            } else if abs(p.x - last.x) + abs(p.y - last.y) < 1 && i != track.count - 1 {
                continue
            } else {
                path.addLine(to: p)
            }
            last = p
        }
        ctx.stroke(path, with: .color(color),
                   style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    /// Dashed great-circle line between two airports (the planned route).
    func drawGreatCircle(_ a: Airport, _ b: Airport) {
        let pts = Geo.greatCircle(a.lat, a.lon, b.lat, b.lon, steps: 96)
        var path = Path()
        var last: CGPoint?
        for (lat, lon) in pts {
            let p = screenNearest(Mercator.project(lat: lat, lon: lon))
            if let l = last, abs(p.x - l.x) <= size.width { path.addLine(to: p) } else { path.move(to: p) }
            last = p
        }
        ctx.stroke(path, with: .color(.white.opacity(0.55)),
                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [6, 5]))
    }

    /// Dot with a label, e.g. an airport.
    func drawMarker(_ p: SIMD2<Double>, color: Color, label: String?) {
        let s = screenNearest(p)
        ctx.fill(Path(ellipseIn: CGRect(x: s.x - 7, y: s.y - 7, width: 14, height: 14)), with: .color(.white))
        ctx.fill(Path(ellipseIn: CGRect(x: s.x - 4.5, y: s.y - 4.5, width: 9, height: 9)), with: .color(color))
        if let label {
            ctx.draw(Text(label).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(.white),
                     at: CGPoint(x: s.x + 9, y: s.y - 9), anchor: .bottomLeading)
        }
    }

    func drawPosition(_ l: CLLocation, heading: CLHeading?) {
        let p = screenNearest(Mercator.project(l.coordinate))
        let stale = Date().timeIntervalSince(l.timestamp) > 10
        let tint: Color = stale ? .gray : Color(red: 0.25, green: 0.6, blue: 1.0)

        // Accuracy circle
        if l.horizontalAccuracy > 0 {
            let r = l.horizontalAccuracy / Mercator.metersPerUnit(atLatitude: l.coordinate.latitude) * scale
            if r > 6 && r < 4000 {
                let circle = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
                ctx.fill(circle, with: .color(tint.opacity(0.15)))
                ctx.stroke(circle, with: .color(tint.opacity(0.5)), lineWidth: 1)
            }
        }

        // Direction: GPS course when moving, otherwise compass heading.
        var dir: Double?
        if l.speed > 1, l.course >= 0 {
            dir = l.course
        } else if let h = heading {
            dir = h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading
        }
        if let dir {
            let a = dir * .pi / 180
            func pt(_ dist: Double, _ ang: Double) -> CGPoint {
                CGPoint(x: p.x + dist * sin(a + ang), y: p.y - dist * cos(a + ang))
            }
            var arrow = Path()
            arrow.move(to: pt(26, 0))
            arrow.addLine(to: pt(12, 0.55))
            arrow.addLine(to: pt(12, -0.55))
            arrow.closeSubpath()
            ctx.fill(arrow, with: .color(tint))
        }

        let dot = Path(ellipseIn: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16))
        ctx.fill(dot, with: .color(.white))
        let inner = Path(ellipseIn: CGRect(x: p.x - 5.5, y: p.y - 5.5, width: 11, height: 11))
        ctx.fill(inner, with: .color(tint))
    }

    // MARK: Scale bar

    func drawScaleBar() {
        let lat = Mercator.latitude(y: min(max(center.y, 0), 1))
        let metersPerPixel = Mercator.metersPerUnit(atLatitude: lat) / scale
        guard metersPerPixel > 0 else { return }
        let maxMeters = metersPerPixel * 110
        let mag = pow(10, floor(log10(maxMeters)))
        let nice = [5.0, 2.0, 1.0].map { $0 * mag }.first { $0 <= maxMeters } ?? mag
        let px = nice / metersPerPixel
        let origin = CGPoint(x: 10, y: size.height - 18)

        var bar = Path()
        bar.move(to: CGPoint(x: origin.x, y: origin.y - 5))
        bar.addLine(to: origin)
        bar.addLine(to: CGPoint(x: origin.x + px, y: origin.y))
        bar.addLine(to: CGPoint(x: origin.x + px, y: origin.y - 5))
        ctx.stroke(bar, with: .color(.white), lineWidth: 2)

        let label = nice >= 1000
            ? String(format: "%g km / %.1f nm", nice / 1000, nice / 1852)
            : String(format: "%g m", nice)
        ctx.draw(Text(label).font(.system(size: 10, design: .monospaced)).foregroundColor(.white),
                 at: CGPoint(x: origin.x, y: origin.y - 7), anchor: .bottomLeading)
    }
}
