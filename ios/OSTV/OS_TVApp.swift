import SwiftUI
import IPTVMacCore

@main
struct OSTVApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(Theme.orange)
                .task { model.bootstrap() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Theme.surface.ignoresSafeArea()
            switch model.phase {
            case .signedOut:
                LoginView()
            case .connecting(let message):
                VStack(spacing: 18) {
                    ProgressView().controlSize(.large).tint(Theme.orange)
                    Text(message).foregroundStyle(Theme.secondaryText)
                }
            case .failed(let message):
                FailureView(message: message)
            case .ready:
                MainTabView()
            }
        }
        .fullScreenCover(item: $model.nowPlaying) { item in
            PlayerView(item: item)
        }
    }
}

private struct FailureView: View {
    @EnvironmentObject private var model: AppModel
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle).foregroundStyle(Theme.orange)
            Text("Could not sign in").font(.headline)
            Text(message).font(.callout).foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Try again") { model.retry() }.buttonStyle(.borderedProminent)
                Button("Use another subscription") { model.signOut() }.buttonStyle(.bordered)
            }
        }
        .padding(28)
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            LiveView()
                .tabItem { Label("Live", systemImage: "tv") }
            MoviesView()
                .tabItem { Label("Movies", systemImage: "film") }
            AccountView()
                .tabItem { Label("Account", systemImage: "gearshape") }
        }
        .background(Theme.surface)
    }
}
