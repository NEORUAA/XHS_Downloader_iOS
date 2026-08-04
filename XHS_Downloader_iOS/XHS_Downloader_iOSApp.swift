import SwiftUI

@main
struct XHS_Downloader_iOSApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var coordinator: DownloadCoordinator

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _coordinator = StateObject(wrappedValue: DownloadCoordinator(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(coordinator: coordinator, settings: settings)
        }
    }
}
