import SwiftUI

@main
struct CarLyricsApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var coordinator = NowPlayingCoordinator.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coordinator)
                .onAppear { coordinator.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            coordinator.scenePhaseChanged(phase)
        }
    }
}
