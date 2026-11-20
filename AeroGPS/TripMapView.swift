import SwiftUI
import CoreLocation

/// Offline map of one trip: recorded track (yellow), great-circle route between the airports (dashed),
/// departure / start (green) and arrival / end (red) markers. Starts zoomed to fit the trip; drag / pinch to explore.
struct TripMapView: View {
    /// Track in mercator unit space.
    let track: [SIMD2<Double>]
    let from: Airport?
    let to: Airport?
    /// Current position while recording.
    var live: CLLocation?
    var showsCities = true

    @State private var center: SIMD2<Double>?
    @State private var zoom: Double?
    @State private var dragStart: SIMD2<Double>?
    @State private var pinchStartZoom: Double?

    private let world = WorldMap.shared
    private let minZoom = 1.0, maxZoom = 15.0

    var body: some View {
        GeometryReader { geo in
            let fit = Self.fit(track: track, from: from, to: to, size: geo.size)
            let cam = center ?? fit.center
            let z = zoom ?? fit.zoom
            ZStack(alignment: .bottomTrailing) {
                Canvas { ctx, size in
                    let r = MapRenderer(ctx: ctx, size: size, center: cam, zoom: z)
                    r.drawBase(world, showCities: showsCities)
                    if let from, let to, from != to { r.drawGreatCircle(from, to) }
                    r.drawTrack(track)
                    // No airport known (drives, or flights not detected yet): mark the track's ends.
                    if from == nil, let p = track.first { r.drawMarker(p, color: .green, label: nil) }
                    if to == nil, live == nil, track.count > 1, let p = track.last { r.drawMarker(p, color: .red, label: nil) }
                    if let from { r.drawMarker(Mercator.project(from.coordinate), color: .green, label: from.iata) }
                    if let to { r.drawMarker(Mercator.project(to.coordinate), color: .red, label: to.iata) }
                    if let live { r.drawPosition(live, heading: nil) }
                    r.drawScaleBar()
                }
                .gesture(dragGesture(cam: cam, zoom: z))
                .simultaneousGesture(pinchGesture(zoom: z))
                .onTapGesture(count: 2) { zoom = min(maxZoom, z + 1) }

                if center != nil || zoom != nil {
                    Button {
                        center = nil
                        zoom = nil
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .foregroundColor(.primary)
                    .padding(10)
                }
            }
        }
        .background(MapRenderer.ocean)
        .clipped()
    }

    private func dragGesture(cam: SIMD2<Double>, zoom z: Double) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                if dragStart == nil { dragStart = cam }
                let scale = MapRenderer.pixelsPerUnit(z)
                var c = dragStart! - SIMD2(Double(g.translation.width), Double(g.translation.height)) / scale
                c.y = min(max(c.y, 0), 1)
                center = c
            }
            .onEnded { _ in dragStart = nil }
    }

    private func pinchGesture(zoom z: Double) -> some Gesture {
        MagnificationGesture()
            .onChanged { v in
                if pinchStartZoom == nil { pinchStartZoom = z }
                zoom = min(max(pinchStartZoom! + log2(Double(v)), minZoom), maxZoom)
            }
            .onEnded { _ in pinchStartZoom = nil }
    }

    /// Camera that shows the whole track and both airports, handling routes across the dateline.
    static func fit(track: [SIMD2<Double>], from: Airport?, to: Airport?,
                    size: CGSize) -> (center: SIMD2<Double>, zoom: Double) {
        var pts = track
        if let a = from { pts.append(Mercator.project(a.coordinate)) }
        if let a = to { pts.append(Mercator.project(a.coordinate)) }
        guard !pts.isEmpty, size.width > 0, size.height > 0 else { return (SIMD2(0.5, 0.4), 1.5) }

        func bounds(_ xs: [Double]) -> (Double, Double) { (xs.min() ?? 0, xs.max() ?? 0) }
        let xs = pts.map(\.x)
        let shifted = xs.map { $0 < 0.5 ? $0 + 1 : $0 }        // same points seen across the dateline
        var (minX, maxX) = bounds(xs)
        let (sMin, sMax) = bounds(shifted)
        if sMax - sMin < maxX - minX { (minX, maxX) = (sMin, sMax) }
        let (minY, maxY) = bounds(pts.map(\.y))

        let center = SIMD2((minX + maxX) / 2, (minY + maxY) / 2)
        let spanX = max(maxX - minX, 1e-6), spanY = max(maxY - minY, 1e-6)
        let usableW = max(Double(size.width) - 60, 50), usableH = max(Double(size.height) - 80, 50)
        let z = log2(min(usableW / (spanX * 256), usableH / (spanY * 256)))
        return (center, min(max(z, 1), 13))
    }
}
