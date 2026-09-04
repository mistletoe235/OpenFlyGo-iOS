import SwiftUI
import UIKit

@main
struct DJIVLNiOSApp: App {
    @StateObject private var model = FlightViewModel()
    @StateObject private var languageSettings = AppLanguageSettings()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(languageSettings)
                .environment(\.locale, languageSettings.language.locale)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        preventAutoLock("scene active")
                        model.resumeDJIConnection()
                    }
                    if phase == .background {
                        UIApplication.shared.isIdleTimerDisabled = false
                        model.enterBackground()
                    }
                    if phase == .inactive {
                        model.enterInactive()
                    }
                }
                .onAppear {
                    preventAutoLock("view appear")
                    model.resumeDJIConnection()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    preventAutoLock("didBecomeActive")
                }
        }
    }

    private func preventAutoLock(_ source: String) {
        UIApplication.shared.isIdleTimerDisabled = true
        print("[系统][防锁屏] \(source)：idleTimerDisabled=\(UIApplication.shared.isIdleTimerDisabled)")
    }
}
