import SwiftUI

/// 深色配色，与桌面端 `main.css` 的 token 一一对应。
/// 手机端不另起一套色板 —— 两个端看起来像同一个产品，靠的就是这份对齐。
enum Theme {
    static let bg = Color(red: 0.051, green: 0.051, blue: 0.055)      // #0D0D0E
    static let panel = Color(red: 0.094, green: 0.094, blue: 0.094)   // #181818
    static let canvas = Color(red: 0.122, green: 0.122, blue: 0.125)  // #1F1F20
    static let raised = Color(red: 0.149, green: 0.149, blue: 0.157)  // #262628
    static let border = Color(red: 0.180, green: 0.180, blue: 0.188)  // #2E2E30
    static let text1 = Color(red: 0.949, green: 0.957, blue: 0.965)   // #F2F4F6
    static let text2 = Color(red: 0.663, green: 0.690, blue: 0.722)   // #A9B0B8
    static let text3 = Color(red: 0.549, green: 0.580, blue: 0.616)   // #8C949D
    static let accent = Color(red: 0.278, green: 0.584, blue: 1.000)  // #4795FF
    static let danger = Color(red: 0.941, green: 0.439, blue: 0.369)  // #F0705E
}

@main
struct StashMobileApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if model.connection.isConnected {
                GalleryView()
                    .transition(.opacity)
            } else {
                ConnectView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.connection.isConnected)
        .task {
            await model.connection.restore()
            model.bind()
        }
        .onChange(of: model.connection.epoch) { _, _ in
            model.bind()
        }
    }
}
