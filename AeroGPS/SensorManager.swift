import Foundation
import CoreLocation
import CoreMotion
import UIKit
import MetricKit

struct LogLine: Identifiable, Hashable {
    let id: Int
    let text: String
}

/// Owns CoreLocation (GPS fixes + compass) and CoreMotion (accelerometer),
/// publishes the latest values for the UI, and keeps a text log of every
/// callback the OS delivers, with every field CLLocation/CLHeading expose.
@MainActor
final class SensorManager: NSObject, ObservableObject {

    // MARK: - Published state (read by the UI)

    @Published private(set) var location: CLLocation?
    @Published private(set) var heading: CLHeading?
    @Published private(set) var accel = CMAcceleration(x: 0, y: 0, z: 0)
    @Published private(set) var authStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var fixCount = 0
    /// Flown track in Web-Mercator unit coordinates (x,y in 0...1), for the map tab.
    @Published private(set) var track: [SIMD2<Double>] = []

    /// Freezes the log (sensors and the live cards keep running).
    @Published var isPaused = false
    /// Also print synthesized $GPGGA / $GPRMC sentences for each fix.
    @Published var emitNMEA = true
    /// Called for every location fix (used by the trip recorder).
    var onFix: (@MainActor (CLLocation) -> Void)?

    // MARK: - Private

    private let lm = CLLocationManager()
    private let mm = CMMotionManager()
    private let maxLines = 4000
    private var nextID = 0
    private var started = false
    private var lastTrackFix: CLLocation?
    private let maxTrackPoints = 50_000
    private var backgroundCapable = false
    private var lastCallback: Date?                 // last time CoreLocation called us at all
    private var lastFreshFix: Date?                 // last fix whose timestamp was < 5 s old on arrival
    private var lastRestart: Date?                  // last start/restart of location updates
    private var restartCount = 0
    private var noFixWarned = false
    private var watchdog: Timer?
    private var watchdogTicks = 0
    private var observers: [NSObjectProtocol] = []
    /// CLBackgroundActivitySession (iOS 17+): keeps a When-In-Use app receiving fixes in the background.
    private var backgroundSession: AnyObject?
    /// Persistent event log (everything except LOC / NMEA / HDG lines), survives the app being killed.
    private var events: FileHandle?
    let eventsURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Logs", isDirectory: true).appendingPathComponent("events.log")
    }()
    private let fileClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let nmeaTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HHmmss.SS"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private let nmeaDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "ddMMyy"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Lifecycle

    override init() {
        super.init()
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        lm.distanceFilter = kCLDistanceFilterNone      // deliver every fix
        lm.activityType = .airborne                     // don't filter "implausible" speeds
        lm.pausesLocationUpdatesAutomatically = false
        lm.headingFilter = 3                            // degrees; keeps HDG lines from flooding

        // Keep receiving fixes when the screen locks or another app is in front.
        // Requires UIBackgroundModes = location in Info.plist; checked so it can never crash.
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        backgroundCapable = modes.contains("location")
        if backgroundCapable {
            lm.allowsBackgroundLocationUpdates = true
            lm.showsBackgroundLocationIndicator = true  // blue pill in the status bar while in background
        }
    }

    func start() {
        guard !started else { return }
        started = true
        UIApplication.shared.isIdleTimerDisabled = true

        // Show how the previous run ended: its last persisted events (the in-memory log is gone).
        let previous = previousEvents(20)
        openEventLog()
        if !previous.isEmpty {
            append("APP  --- last \(previous.count) events of the previous run (from events.log) ---", persist: false)
            for line in previous { append("PREV \(line)", persist: false) }
            append("APP  --- end of previous run ---", persist: false)
        }
        MXMetricManager.shared.add(self)

        append("APP  start device=\(UIDevice.current.model) iOS=\(UIDevice.current.systemVersion)")
        append("APP  headingAvailable=\(CLLocationManager.headingAvailable()) accelAvailable=\(mm.isAccelerometerAvailable)")
        append("APP  backgroundLocation=\(backgroundCapable) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled) "
               + "thermal=\(thermalName) battery=\(batteryText)")
        observeSystemEvents()
        startWatchdog()

        // Location + heading are started in locationManagerDidChangeAuthorization.
        lm.requestWhenInUseAuthorization()

        if mm.isAccelerometerAvailable {
            mm.accelerometerUpdateInterval = 1.0 / 10.0
            mm.startAccelerometerUpdates(to: .main) { [weak self] data, error in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let error {
                        self.append("ACC  error \(error.localizedDescription)")
                        return
                    }
                    if let data { self.accel = data.acceleration }
                }
            }
        }
    }

    func clearLog() {
        log.removeAll()
        nextID = 0
    }

    func clearTrack() {
        track.removeAll()
        lastTrackFix = nil
    }

    /// Adds a fix to the track if it is reasonably accurate and has moved at least 10 m.
    private func addToTrack(_ l: CLLocation) {
        guard l.horizontalAccuracy >= 0, l.horizontalAccuracy <= 150 else { return }
        if let last = lastTrackFix, l.distance(from: last) < 10 { return }
        lastTrackFix = l
        track.append(Mercator.project(l.coordinate))
        if track.count > maxTrackPoints {
            track.removeFirst(track.count - maxTrackPoints + 1000)
        }
    }

    // MARK: - System events and watchdog

    private var thermalName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "SERIOUS"
        case .critical: return "CRITICAL"
        @unknown default: return "unknown"
        }
    }

    private var batteryText: String {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level < 0 ? "?" : "\(Int(level * 100))%"
    }

    /// Logs everything that can make iOS stop delivering fixes, so gaps in the log can be explained.
    private func observeSystemEvents() {
        let nc = NotificationCenter.default
        func on(_ name: Notification.Name, _ action: @escaping @MainActor () -> Void) {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { action() }
            })
        }
        on(UIApplication.didBecomeActiveNotification) { [weak self] in
            // Re-assert every time: iOS can drop this after the app has been in the background.
            UIApplication.shared.isIdleTimerDisabled = true
            self?.append("APP  active (foreground)")
        }
        on(UIApplication.willResignActiveNotification) { [weak self] in
            self?.append("APP  resign active (Control Center, call, lock, app switch…)")
        }
        on(UIApplication.didEnterBackgroundNotification) { [weak self] in
            guard let self else { return }
            self.append(self.backgroundCapable
                ? "APP  background - GPS keeps running"
                : "APP  background - iOS will suspend the app, GPS stops")
        }
        on(UIApplication.willEnterForegroundNotification) { [weak self] in
            self?.append("APP  will enter foreground")
        }
        on(UIApplication.protectedDataWillBecomeUnavailableNotification) { [weak self] in
            self?.append("APP  screen locked")
        }
        on(UIApplication.protectedDataDidBecomeAvailableNotification) { [weak self] in
            self?.append("APP  screen unlocked")
        }
        on(.NSProcessInfoPowerStateDidChange) { [weak self] in
            self?.append("APP  low power mode=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        }
        on(ProcessInfo.thermalStateDidChangeNotification) { [weak self] in
            guard let self else { return }
            self.append("APP  thermal state=\(self.thermalName)")
        }
    }

    /// Every 5 s: warn when no fresh fix has arrived, and restart location updates
    /// if the GPS has been silent or stale for 60 s (at most once every 60 s).
    private func startWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkWatchdog() }
        }
    }

    private func checkWatchdog() {
        let now = Date()
        // Heartbeat every 60 s, file only: the last BEAT shows when and in which state the app stopped running.
        watchdogTicks += 1
        if watchdogTicks % 12 == 0 {
            let fresh = lastFreshFix.map { "\(Int(now.timeIntervalSince($0)))s ago" } ?? "never"
            writeEvent("BEAT state=\(appStateName) fixes=\(fixCount) lastFreshFix=\(fresh) "
                       + "battery=\(batteryText) thermal=\(thermalName) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        }
        guard authStatus == .authorizedWhenInUse || authStatus == .authorizedAlways else { return }
        let since = now.timeIntervalSince(lastFreshFix ?? lastRestart ?? now)
        if since >= 20 && !noFixWarned {
            noFixWarned = true
            let cb = lastCallback.map { "\(Int(now.timeIntervalSince($0)))s ago" } ?? "never"
            append("WARN no fresh fix for \(Int(since))s (last callback \(cb)) - weak sky view? hold phone at window")
        }
        // First restart after 60 s, then at most every 5 min so a satellite search in progress isn't cut short.
        let minGap: TimeInterval = restartCount == 0 ? 60 : 300
        if since >= 60, now.timeIntervalSince(lastRestart ?? .distantPast) >= minGap {
            lastRestart = now
            restartCount += 1
            // Never stop location updates while not in the foreground: with When-In-Use permission,
            // stopping them there ends the app's right to run in the background and iOS suspends it
            // before they can be started again. That silently ended recordings with the screen locked.
            guard UIApplication.shared.applicationState == .active else {
                append("APP  watchdog: no fresh fix for \(Int(since))s, app in \(appStateName) - not restarting "
                       + "(would suspend the app); CoreLocation keeps searching")
                return
            }
            lm.stopUpdatingLocation()
            lm.startUpdatingLocation()
            append("APP  watchdog: restarted location updates (#\(restartCount)), no fresh fix for \(Int(since))s")
        }
    }

    var logText: String {
        log.map(\.text).joined(separator: "\n")
    }

    var authName: String {
        switch authStatus {
        case .notDetermined:       return "not determined"
        case .restricted:          return "restricted"
        case .denied:              return "denied"
        case .authorizedAlways:    return "always"
        case .authorizedWhenInUse: return "when in use"
        @unknown default:          return "unknown"
        }
    }

    // MARK: - Logging

    private func append(_ text: String, persist: Bool = true) {
        if persist && !(text.hasPrefix("LOC") || text.hasPrefix("$GP") || text.hasPrefix("HDG")) {
            writeEvent(text)
        }
        guard !isPaused else { return }
        log.append(LogLine(id: nextID, text: "\(clock.string(from: Date())) \(text)"))
        nextID += 1
        if log.count > maxLines {
            log.removeFirst(log.count - maxLines)
        }
    }

    // MARK: - Persistent event log

    private func openEventLog() {
        let fm = FileManager.default
        try? fm.createDirectory(at: eventsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep the file small: when it passes 2 MB, keep the last 1 MB.
        if let size = (try? fm.attributesOfItem(atPath: eventsURL.path))?[.size] as? Int, size > 2_000_000,
           let data = try? Data(contentsOf: eventsURL) {
            var tail = data.suffix(1_000_000)
            if let nl = tail.firstIndex(of: 0x0A) { tail = tail[(nl + 1)...] }   // start on a whole line
            try? Data(tail).write(to: eventsURL, options: .atomic)
        }
        if !fm.fileExists(atPath: eventsURL.path) {
            fm.createFile(atPath: eventsURL.path, contents: nil)
        }
        events = try? FileHandle(forWritingTo: eventsURL)
        _ = try? events?.seekToEnd()
    }

    private func writeEvent(_ text: String) {
        guard let events else { return }
        let line = "\(fileClock.string(from: Date())) \(text)\n"
        try? events.write(contentsOf: Data(line.utf8))
    }

    private func previousEvents(_ n: Int) -> [String] {
        guard let data = try? Data(contentsOf: eventsURL) else { return [] }
        let text = String(decoding: data.suffix(20_000), as: UTF8.self)
        return text.split(separator: "\n").suffix(n).map(String.init)
    }

    private var appStateName: String {
        switch UIApplication.shared.applicationState {
        case .active:     return "active"
        case .inactive:   return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private func f(_ v: Double, _ decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f", v)
    }

    // MARK: - Handlers (always on the main actor)

    fileprivate func handleAuthorization(_ manager: CLLocationManager) {
        authStatus = manager.authorizationStatus
        let precise = manager.accuracyAuthorization == .fullAccuracy ? "full" : "reduced"
        append("AUTH status=\(authName) accuracy=\(precise)")

        switch authStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
            lastRestart = Date()
            if #available(iOS 17.0, *), backgroundCapable, backgroundSession == nil {
                backgroundSession = CLBackgroundActivitySession()
                append("APP  background activity session started")
            }
            if CLLocationManager.headingAvailable() {
                manager.startUpdatingHeading()
            }
            append("APP  startUpdatingLocation + startUpdatingHeading")
        case .denied, .restricted:
            append("APP  location not allowed - enable it in Settings > Privacy > Location Services")
        default:
            break
        }
    }

    fileprivate func handleLocations(_ locations: [CLLocation]) {
        let now = Date()
        if let last = lastCallback, now.timeIntervalSince(last) > 5 {
            append("GAP  no location callbacks for \(Int(now.timeIntervalSince(last)))s")
        }
        lastCallback = now
        for l in locations {
            let age = now.timeIntervalSince(l.timestamp)
            if age < 5 && l.horizontalAccuracy >= 0 {
                if noFixWarned, let lf = lastFreshFix {
                    append("APP  fresh fix again after \(Int(now.timeIntervalSince(lf)))s")
                }
                lastFreshFix = now
                noFixWarned = false
                restartCount = 0
            }
            fixCount += 1
            location = l
            addToTrack(l)
            onFix?(l)
            append(describe(l))
            if emitNMEA {
                append(nmeaGGA(l))
                append(nmeaRMC(l))
            }
        }
    }

    fileprivate func handleHeading(_ h: CLHeading) {
        heading = h
        append("HDG  mag=\(f(h.magneticHeading))° true=\(f(h.trueHeading))° acc=\(f(h.headingAccuracy))° "
               + "field(uT) x=\(f(h.x, 1)) y=\(f(h.y, 1)) z=\(f(h.z, 1))")
    }

    fileprivate func handleError(_ error: Error) {
        let e = error as NSError
        lastCallback = Date()
        if e.domain == kCLErrorDomain, e.code == CLError.locationUnknown.rawValue {
            append("ERR  code=0 locationUnknown - no fix right now, CoreLocation keeps trying")
        } else {
            append("ERR  domain=\(e.domain) code=\(e.code) \(e.localizedDescription)")
        }
    }

    // MARK: - Formatting

    /// One line with every field CLLocation exposes. Negative accuracy = field invalid.
    private func describe(_ l: CLLocation) -> String {
        let c = l.coordinate
        let age = Date().timeIntervalSince(l.timestamp)
        let floor = l.floor.map { String($0.level) } ?? "-"
        let src = l.sourceInformation.map {
            "sim=\($0.isSimulatedBySoftware ? 1 : 0) acc=\($0.isProducedByAccessory ? 1 : 0)"
        } ?? "src=-"

        return "LOC  #\(fixCount) fix=\(iso.string(from: l.timestamp)) age=\(f(age, 2))s "
             + "lat=\(f(c.latitude, 7)) lon=\(f(c.longitude, 7)) hAcc=\(f(l.horizontalAccuracy))m "
             + "alt=\(f(l.altitude))m ellAlt=\(f(l.ellipsoidalAltitude))m vAcc=\(f(l.verticalAccuracy))m "
             + "spd=\(f(l.speed, 2))m/s spdAcc=\(f(l.speedAccuracy, 2)) "
             + "crs=\(f(l.course))° crsAcc=\(f(l.courseAccuracy)) floor=\(floor) \(src)"
    }

    // NMEA sentences are synthesized from CLLocation so the log looks like a
    // receiver stream; iOS does not expose the real NMEA/raw GNSS data.

    private func nmeaCoord(_ v: Double, isLat: Bool) -> (String, String) {
        let a = abs(v)
        let deg = Int(a)
        let min = (a - Double(deg)) * 60
        let body = isLat ? String(format: "%02d%07.4f", deg, min)
                         : String(format: "%03d%07.4f", deg, min)
        let hemi = isLat ? (v >= 0 ? "N" : "S") : (v >= 0 ? "E" : "W")
        return (body, hemi)
    }

    private func nmea(_ fields: [String]) -> String {
        let body = fields.joined(separator: ",")
        var cs: UInt8 = 0
        for b in body.utf8 { cs ^= b }
        return "$" + body + String(format: "*%02X", cs)
    }

    private func nmeaGGA(_ l: CLLocation) -> String {
        let (lat, ns) = nmeaCoord(l.coordinate.latitude, isLat: true)
        let (lon, ew) = nmeaCoord(l.coordinate.longitude, isLat: false)
        let valid = l.horizontalAccuracy >= 0
        let hasAlt = l.verticalAccuracy >= 0
        let alt = hasAlt ? f(l.altitude) : ""
        let geoid = hasAlt ? f(l.ellipsoidalAltitude - l.altitude) : ""
        return nmea(["GPGGA", nmeaTime.string(from: l.timestamp), lat, ns, lon, ew,
                     valid ? "1" : "0", "", "", alt, "M", geoid, "M", "", ""])
    }

    private func nmeaRMC(_ l: CLLocation) -> String {
        let (lat, ns) = nmeaCoord(l.coordinate.latitude, isLat: true)
        let (lon, ew) = nmeaCoord(l.coordinate.longitude, isLat: false)
        let valid = l.horizontalAccuracy >= 0
        let knots = l.speed >= 0 ? f(l.speed * 1.943844, 2) : ""
        let course = l.course >= 0 ? f(l.course) : ""
        return nmea(["GPRMC", nmeaTime.string(from: l.timestamp), valid ? "A" : "V",
                     lat, ns, lon, ew, knots, course,
                     nmeaDate.string(from: l.timestamp), "", "", "A"])
    }
}

// MARK: - CLLocationManagerDelegate
//
// CLLocationManager delivers callbacks on the thread it was created on (main),
// so hopping onto the main actor with assumeIsolated is safe here.

extension SensorManager: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { handleAuthorization(manager) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated { handleLocations(locations) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        MainActor.assumeIsolated { handleHeading(newHeading) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { handleError(error) }
    }

    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        true
    }
}

// MARK: - MetricKit
//
// iOS reports why the app was terminated (memory limit, CPU limit, crash, …) in later payloads:
// exit counts about once a day, crash diagnostics on the next launch. They go to the event log.

extension SensorManager: MXMetricManagerSubscriber {

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        var lines: [String] = []
        for p in payloads {
            guard let exits = p.applicationExitMetrics else { continue }
            let b = exits.backgroundExitData
            lines.append("EXIT background exits \(p.timeStampBegin)–\(p.timeStampEnd): "
                + "normal=\(b.cumulativeNormalAppExitCount) memoryLimit=\(b.cumulativeMemoryResourceLimitExitCount) "
                + "memoryPressure=\(b.cumulativeMemoryPressureExitCount) cpuLimit=\(b.cumulativeCPUResourceLimitExitCount) "
                + "watchdog=\(b.cumulativeAppWatchdogExitCount) crash=\(b.cumulativeAbnormalExitCount) "
                + "badAccess=\(b.cumulativeBadAccessExitCount) illegalInstr=\(b.cumulativeIllegalInstructionExitCount) "
                + "lockedFile=\(b.cumulativeSuspendedWithLockedFileExitCount) "
                + "taskTimeout=\(b.cumulativeBackgroundTaskAssertionTimeoutExitCount)")
            let f = exits.foregroundExitData
            lines.append("EXIT foreground exits: normal=\(f.cumulativeNormalAppExitCount) "
                + "memoryLimit=\(f.cumulativeMemoryResourceLimitExitCount) watchdog=\(f.cumulativeAppWatchdogExitCount) "
                + "crash=\(f.cumulativeAbnormalExitCount) badAccess=\(f.cumulativeBadAccessExitCount)")
        }
        guard !lines.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { lines.forEach { self?.append($0) } }
        }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var lines: [String] = []
        for p in payloads {
            for c in p.crashDiagnostics ?? [] {
                lines.append("CRASH \(p.timeStampBegin): exception=\(c.exceptionType.map { "\($0)" } ?? "-") "
                    + "code=\(c.exceptionCode.map { "\($0)" } ?? "-") signal=\(c.signal.map { "\($0)" } ?? "-") "
                    + "reason=\(c.terminationReason ?? "-")")
            }
            for c in p.cpuExceptionDiagnostics ?? [] {
                lines.append("CPU  \(p.timeStampBegin): too much CPU in background, \(c.totalCPUTime) over \(c.totalSampledTime)")
            }
        }
        guard !lines.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { lines.forEach { self?.append($0) } }
        }
    }
}
