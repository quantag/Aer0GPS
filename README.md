# AeroGPS

iOS app with three tabs:

- **Data**: live GPS position, accelerometer and compass, plus a scrollable log of
  every location/heading callback iOS delivers (all fields) and synthesized NMEA
  `$GPGGA` / `$GPRMC` lines.
- **Map**: a fully offline world map (no network, no tiles) with your position,
  accuracy circle, direction arrow and flown track.
- **Trips**: record flights, keep every trip, see statistics, view each route on the
  map and export a flight logbook.

## What "low level" means on iOS

iOS does **not** expose raw GNSS data (no NMEA stream from the chip, no satellite
count / SNR, no pseudoranges — that exists only on Android). The lowest level you
can get is every `CLLocation` and `CLHeading` object CoreLocation emits, with every
field it carries. That is exactly what this app logs:

```
15:19:04.123 LOC  #42 fix=2026-10-22T13:19:04.001Z age=0.12s lat=59.9139012 lon=10.7522345 hAcc=4.8m alt=11.9m ellAlt=51.2m vAcc=3.1m spd=0.00m/s spdAcc=0.52 crs=-1.0° crsAcc=-1.0 floor=- sim=0 acc=0
15:19:04.124 $GPGGA,131904.00,5954.8341,N,01045.1341,E,1,,,11.9,M,39.3,M,,*5C
15:19:04.124 $GPRMC,131904.00,A,5954.8341,N,01045.1341,E,0.00,,221026,,,A*6B
15:19:05.210 HDG  mag=187.3° true=190.9° acc=15.0° field(uT) x=-12.3 y=21.7 z=-39.0
```

- Negative accuracy (`hAcc`, `vAcc`, `spdAcc`, `crsAcc`) or `-1` course/speed means
  the field is invalid for that fix.
- `alt` is height above mean sea level; `ellAlt` is WGS-84 ellipsoid height.
- `sim=1` means the fix was simulated by software; `acc=1` means it came from an
  external accessory (e.g. a Bluetooth GPS).
- The NMEA sentences are generated from the CLLocation values (satellite count and
  HDOP are left empty because iOS doesn't provide them). Turn them off with the
  NMEA button if you only want the raw lines.

## Build and run

This folder is a complete Xcode project. Nothing to configure except signing.

1. Double-click `AeroGPS.xcodeproj`.
2. In the Project navigator click the blue **AeroGPS** project icon → select
   the **AeroGPS** target → **Signing & Capabilities** tab → set **Team** to
   your Apple ID. (If the Team menu is empty: Xcode → Settings → Accounts → +,
   sign in, then come back. A free Apple ID / "Personal Team" is enough.)
   If Xcode complains the bundle identifier is taken, change
   `com.ogray.aerogps` to anything unique on the same tab.
3. Connect your iPhone by cable, unlock it, tap **Trust**.
4. In the toolbar's device menu pick your iPhone (not a simulator) and press
   **Run** (⌘R).
5. First time only, the phone asks for **Developer Mode**
   (Settings → Privacy & Security → Developer Mode → on, restart) and to trust
   the developer app (Settings → General → VPN & Device Management). Run again.
6. In the app, allow location with **Precise: On**.

With a free Apple ID the installed app expires after 7 days; just run it from
Xcode again.

The Simulator can fake a location (Features → Location) but has no
accelerometer or compass, so use a real device.

Project facts: SwiftUI, Swift 5 language mode, deployment target iOS 16.0,
`Info.plist` is generated from build settings (the location permission string is
`INFOPLIST_KEY_NSLocationWhenInUseUsageDescription` in the target's Build
Settings). The accelerometer via `CMMotionManager` needs no motion permission key.

## Using it on a plane

- GPS keeps working in Airplane Mode — only the cellular/Wi-Fi/Bluetooth radios are
  switched off. Location Services stays on.
- Hold the phone against the window. The fuselage blocks most of the sky.
- Without a data connection there is no assistance data, so the first fix can take
  several minutes (cold start). Getting a fix on the ground before boarding helps.
- Expect `spd` around 220–260 m/s at cruise and `alt` around 10–12 km.
  `activityType = .airborne` is set so CoreLocation does not discard those as
  implausible.
- The compass (magnetometer) inside a metal fuselage will be unreliable; the `acc`
  (accuracy) value shows how much to trust it. `true` heading needs a GPS fix.
- The accelerometer reports in g including gravity, so `|a|` ≈ 1.0 at rest and
  varies with turbulence.
- The screen is kept awake while the app is in front. Use the share button
  (top-right of the controls row) to export the log as text.

## Screen lock, background and GPS gaps

The app has the **Location updates** background mode, so GPS, compass, the log
and the track keep running when the screen locks or you switch apps. While it is
in the background iOS shows a blue location pill in the status bar.

Without it, iOS suspends the app as soon as the screen locks: no fixes, no
compass, nothing is logged. When the app comes back, CoreLocation first hands
over old cached fixes (large `age=`) with `locationUnknown` errors, and the GPS
chip then needs time to find satellites again through the window.

Extra log lines that explain gaps:

- `APP  active / resign active / background / will enter foreground`
- `APP  screen locked / screen unlocked`, `low power mode=…`, `thermal state=…`
- `GAP  no location callbacks for Ns` — iOS sent nothing for that long
- `WARN no fresh fix for Ns` — callbacks may arrive, but only stale fixes
- `APP  watchdog: restarted location updates` — after 60 s with no fresh fix,
  then at most every 5 min
- `ERR  code=0 locationUnknown` — no fix right now; CoreLocation keeps trying

Running GPS continuously with the screen off uses battery; a 2-hour flight
typically costs 10–20 %.

App Store note: in review notes, explain that background location is used to
keep recording the flight track while the screen is locked.

## Map tab

The map is drawn from `worldmap.bin` (1.1 MB, bundled in the app), made from
[Natural Earth](https://www.naturalearthdata.com) 1:50m land, lakes, country
borders and ~1,250 cities. Natural Earth is public domain. It works anywhere,
including in Airplane Mode, because nothing is downloaded.

- Drag to pan, pinch or double-tap to zoom, the location button re-centres and
  follows you again.
- Blue dot = position (grey if the last fix is older than 10 s), faint circle =
  horizontal accuracy, arrow = GPS course when moving faster than 1 m/s,
  otherwise compass heading.
- Yellow line = flown track: fixes better than 150 m accuracy, one point per 10 m
  moved, up to 50,000 points. The trash button clears it.
- Lat/lon grid lines with labels, scale bar in km and nautical miles, and a top
  panel with position (degrees + decimal minutes), ground speed in knots and
  km/h, track, altitude in ft and m.
- 1:50m coastlines are accurate to roughly 1 km: good for following a flight,
  not for street-level navigation. Zoom beyond ~10 still works for the position
  and track, but the coastline will look coarse.

`worldmap.bin` format (little-endian; coordinates pre-projected to Web Mercator
unit space, x and y in 0...1): `"WMAP"`, u32 version=1, u32 layerCount=6, then
layers land/land-coarse/lakes/lakes-coarse/borders/borders-coarse as
`u32 shapes { u32 rings { u32 n, n × (f32 x, f32 y) } }`, then
`u32 cities { f32 x, f32 y, u8 scalerank, u8 len, UTF-8 name }`.

## Trips tab

- **Start recording now** starts a trip immediately; details can be added later.
  **New trip with flight details…** lets you enter From / To (IATA or ICAO code, or
  search by city), flight number, airline, aircraft, seat and notes first.
- **Airports are detected automatically**: the departure is the airport nearest
  (within 10 km) to the start of the takeoff roll, the arrival the one nearest to
  the end of the landing roll. A code you typed is never replaced, except with
  **Detect airports from track** on the trip screen.
- "Airborne" means sustained ground speed above 35 m/s (68 kt). Flight time is from
  the first to the last moment at that speed. If recording started or stopped in
  the air, the value is marked *partial*.
- Statistics per trip: flight time, recorded time, distance flown, great-circle
  route distance, max and average ground speed, max altitude, max climb / descent
  rate, number of fixes and longest GPS gap. The list shows totals for all trips
  (air time, distance, airports and countries, highest, fastest, longest).
- Tap a trip to see its route on the offline map (recorded track in yellow,
  great-circle route dashed, departure green, arrival red), plus an altitude /
  speed profile. The map has a full-screen mode.
- Export: one trip as GPX, CSV (every fix) or a text summary; the share button in
  the list exports the whole logbook as CSV (one row per flight) plus one GPX
  with all tracks.
- Recording keeps at most one point per second (about 3 MB for a 10-hour flight),
  skips stale fixes, and writes to disk every 10 s. If the app is killed while
  recording, the trip continues recording after the next launch.

Storage: `Application Support/Trips/<uuid>/trip.json` (details + cached
statistics) and `points.csv` (`t,lat,lon,alt,hAcc,vAcc,spd,spdAcc,crs` per line).
Included in device backups.

Airports: `airports.tsv` (~7,950 airports with an IATA code, 630 KB) is built from
[airportsdata](https://github.com/mborsetti/airportsdata) (MIT). Columns: IATA,
ICAO, name, city, country, lat, lon, time zone. Takeoff and landing times are shown
in the airport's local time.

## Tuning

In `SensorManager.init()`:

- `headingFilter = 3` — degrees of change needed before a new `HDG` line.
  Set to `kCLHeadingFilterNone` for every update (very chatty).
- `maxLines = 4000` — log ring-buffer size.
- `accelerometerUpdateInterval = 1/10` — accelerometer refresh rate for the card.
