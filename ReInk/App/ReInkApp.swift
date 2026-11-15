import SwiftUI

@main
struct ReInkApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

enum AppTab: Hashable {
    case create
    case library
    case device
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: AppTab = .create

    var body: some View {
        TabView(selection: $tab) {
            Tab("Create", systemImage: "paintbrush.pointed", value: AppTab.create) {
                CreateView()
            }
            Tab("Library", systemImage: "square.stack", value: AppTab.library) {
                LibraryView(openInEditor: { tab = .create })
            }
            Tab("Case", systemImage: "iphone.gen3", value: AppTab.device) {
                DeviceView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            NFCStatusView()
        }
    }
}
