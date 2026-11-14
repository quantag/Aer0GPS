import SwiftUI

@main
struct AeroGPSApp: App {
    @StateObject private var sensors = SensorManager()
    @StateObject private var trips = TripStore()

    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView()
                    .tabItem { Label("Data", systemImage: "list.bullet.rectangle") }
                MapScreen()
                    .tabItem { Label("Map", systemImage: "map") }
                TripsScreen()
                    .tabItem { Label("Trips", systemImage: "airplane") }
            }
            .environmentObject(sensors)
            .environmentObject(trips)
            .onAppear {
                let store = trips
                sensors.onFix = { [weak store] l in store?.ingest(l) }
                sensors.start()
            }
        }
    }
}
