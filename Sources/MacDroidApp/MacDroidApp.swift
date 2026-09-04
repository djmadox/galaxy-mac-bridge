import SwiftUI

@main
struct MacDroidApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        MenuBarExtra("MacDroid", systemImage: "iphone.and.arrow.forward") {
            MenuBarPanel()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)

        Window("SMS", id: "sms") {
            MessagesView()
                .environmentObject(store)
        }
        .defaultSize(width: 980, height: 680)

        Window("RCS – Google Messages", id: "rcs") {
            RCSWebView()
        }
        .defaultSize(width: 1100, height: 760)

        Window("MacDroid", id: "main") {
            ContentView()
                .environmentObject(store)
        }
        .defaultSize(width: 1050, height: 720)

        Settings {
            SettingsPanel()
                .environmentObject(store)
                .frame(width: 820, height: 620)
        }
    }
}
