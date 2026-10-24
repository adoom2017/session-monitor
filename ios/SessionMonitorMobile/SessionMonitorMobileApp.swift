import SMProtocol
import SwiftUI

@main
struct SessionMonitorMobileApp: App {
  @State private var model = MobileModel()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(model)
        .tint(Theme.blue)
        // Pairing links from the camera app, Notes or a paste: sessionmonitor://pair?d=…
        .onOpenURL { url in
          if url.host == "pair" { Task { await model.pair(link: url) } }
        }
        #if DEBUG
          // Simulator testing without taps: `simctl launch … -SMPairLink '<link>'`.
          .task {
            if let link = UserDefaults.standard.string(forKey: "SMPairLink"), let url = URL(string: link),
              model.servers.isEmpty
            {
              await model.pair(link: url)
            }
          }
        #endif
    }
    .onChange(of: scenePhase) { _, phase in
      // iOS suspends background sockets; reconnect (and get a fresh snapshot) when active again.
      switch phase {
      case .active: if model.current != nil { model.connect() }
      case .background: model.disconnect()
      default: break
      }
    }
  }
}

struct RootView: View {
  @Environment(MobileModel.self) private var model

  @State private var path: [String] = []

  var body: some View {
    if model.servers.isEmpty {
      PairingView()
    } else {
      NavigationStack(path: $path) { SessionListView() }
        #if DEBUG
          // `-SMOpenSession <id>` opens a session once it is listed (screenshots in testing).
          .onChange(of: model.sessions.count) {
            if path.isEmpty, let id = UserDefaults.standard.string(forKey: "SMOpenSession"),
              model.sessions[id] != nil
            {
              path = [id]
            }
          }
        #endif
    }
  }
}
