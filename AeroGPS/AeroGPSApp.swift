import SwiftUI

@main
struct AeroGPSApp: App {
    @StateObject private var sensors = SensorManager()

    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView()
                    .tabItem { Label("Data", systemImage: "list.bullet.rectangle") }
                MapScreen()
                    .tabItem { Label("Map", systemImage: "map") }
            }
            .environmentObject(sensors)
            .onAppear { sensors.start() }
        }
    }
}
