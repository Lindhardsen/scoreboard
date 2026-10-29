import SwiftUI

@main
struct ScoreboardWatchApp: App {
    @StateObject private var store = ScoreStore(api: ScoreboardClient(), credentials: KeychainCredentialsStore())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                if store.credentials == nil {
                    ConfigView(store: store)
                } else {
                    TabView {
                        PointsView(store: store)
                        SetsView(store: store)
                        NamesView(store: store)
                    }
                    .tabViewStyle(.verticalPage)
                }
            }
            .task {
                #if DEBUG
                // UI tests can't type on the watch keyboard; they pass credentials at launch instead.
                let defaults = UserDefaults.standard
                if let server = defaults.string(forKey: "uitestServer"),
                   let username = defaults.string(forKey: "uitestUsername"),
                   let password = defaults.string(forKey: "uitestPassword") {
                    store.signOut()
                    try? await store.signIn(server: server, username: username, password: password)
                }
                #endif
                await store.refresh()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await store.refresh() }
                }
            }
        }
    }
}
