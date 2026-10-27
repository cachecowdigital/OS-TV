import SwiftUI
import AVKit
import IPTVMacCore

struct MoviesView: View {
    @EnvironmentObject private var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(model.visibleMovies) { movie in
                        Button { model.play(movie) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                AsyncImage(url: movie.iconURL.flatMap(URL.init(string:))) { image in
                                    image.resizable().aspectRatio(2.0 / 3.0, contentMode: .fill)
                                } placeholder: {
                                    Rectangle().fill(Theme.panel)
                                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                                        .overlay(ProgressView().tint(Theme.secondaryText))
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                Text(movie.name).font(.caption).lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }
            .background(Theme.surface)
            .searchable(text: $model.searchText, prompt: "Search movies")
            .navigationTitle("Movies")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if model.movies.isEmpty {
                    ContentUnavailableView("No movies", systemImage: "film",
                                           description: Text("This account has no movie catalogue, or it has not loaded yet."))
                }
            }
        }
    }
}

/// Full-screen playback. `AVPlayer` is the streaming engine; the state of the item is
/// mirrored into the log so a slow or refused stream is diagnosable without Xcode.
struct PlayerView: View {
    @EnvironmentObject private var model: AppModel
    let item: AppModel.NowPlaying
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @State private var statusText = "Opening…"
    @State private var failed = false
    @State private var observer: NSKeyValueObservation?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: player)
                .ignoresSafeArea()
                .onAppear { start() }
                .onDisappear {
                    observer?.invalidate()
                    player.pause()
                    Log.write("player: closed \"\(item.title)\"")
                }
            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.headline)
                        Text(statusText).font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2).symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                    }
                }
                .padding()
                .background(.black.opacity(0.55))
                Spacer()
                if failed {
                    VStack(spacing: 10) {
                        Text("This stream did not start.").font(.subheadline)
                        Text("The provider may be at its connection limit, or this channel may be offline.")
                            .font(.caption).foregroundStyle(Theme.secondaryText)
                            .multilineTextAlignment(.center)
                        Button("Try again") { start() }.buttonStyle(.borderedProminent).tint(Theme.orange)
                    }
                    .padding()
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                    .padding()
                }
            }
        }
        .onDisappear { model.stopPlayback() }
        .statusBarHidden()
    }

    private func start() {
        failed = false
        statusText = "Opening…"
        let asset = AVURLAsset(url: item.url)
        let newItem = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: newItem)
        player.play()
        Log.write("player: opening \"\(item.title)\" \(item.url.host ?? "?")\(item.url.path)")

        observer = newItem.observe(\.status, options: [.new]) { observed, _ in
            Task { @MainActor in
                switch observed.status {
                case .readyToPlay:
                    statusText = item.isLive ? "Live" : "Playing"
                    Log.write("player: ready \"\(item.title)\" duration=\(observed.duration.seconds)")
                case .failed:
                    statusText = "Failed"
                    failed = true
                    Log.write("player: FAILED \"\(item.title)\" \(observed.error?.localizedDescription ?? "unknown")")
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
    }
}
