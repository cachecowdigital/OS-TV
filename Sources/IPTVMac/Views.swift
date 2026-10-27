import SwiftUI
import AVKit
import AppKit
import Combine
import IPTVMacCore

enum AppViewMode: String, CaseIterable {
    case list, guide
    var label: String { self == .list ? "Channels" : "Guide" }
    var symbol: String { self == .list ? "list.bullet" : "calendar" }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if !model.isSignedIn {
                LoginView()
            } else if model.isFullScreenPlayer {
                // Full screen is video only: no sidebar, no list, no guide.
                FullScreenPlayerView()
            } else {
                MainView()
            }
        }
        .frame(minWidth: 1120, minHeight: 700)
        .background(Brand.surface)
        .preferredColorScheme(colorScheme)
        .onAppear { applyAppearance() }
        .onChange(of: model.settings.data.appearance) { _ in applyAppearance() }
        // The window's own full-screen state is the single source of truth, so the
        // green button, ⌃⌘F and the in-app buttons can never disagree.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            model.isFullScreenPlayer = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            model.isFullScreenPlayer = false
        }
        // The accent tints system controls — buttons, selection highlights, switches. The
        // brand chrome keeps the brand colours, so this is a tint rather than a repaint:
        // before it, the Accent picker changed nothing whatsoever.
        .tint(model.settings.data.accent == .teal ? Brand.tealLifted : Brand.orange)
    }

    private var colorScheme: ColorScheme? {
        switch model.settings.data.appearance {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }

    /// Set the AppKit appearance too: several controls (sidebar, search field,
    /// table headers) are AppKit-backed and ignore SwiftUI's preference.
    private func applyAppearance() {
        switch model.settings.data.appearance {
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .system: NSApp.appearance = nil
        }
    }
}

// MARK: - Login

struct LoginView: View {
    @EnvironmentObject private var model: AppModel

    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var remember = true
    @State private var working = false

    private var connecting: Bool {
        if case .connecting = model.phase { return true }
        return working
    }

    var body: some View {
        ZStack {
            Brand.surface.ignoresSafeArea()
            VStack(spacing: 26) {
                Spacer(minLength: 0)
                BrandLockup(width: 360)
                Text("Your subscription, your player.")
                    .font(.title3).foregroundStyle(Brand.textMuted)

                // Reachable after a plain Sign Out, or on a fresh launch before anything has
                // auto-connected — without this, a saved subscription was only reachable by
                // retyping its server, username and password from scratch, even though it was
                // sitting right there in Manage Subscriptions the whole time.
                if !model.subscriptions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Saved subscriptions").font(.caption).foregroundStyle(Brand.textMuted)
                        ForEach(model.subscriptions) { playlist in
                            Button {
                                working = true
                                Task {
                                    await model.switchSubscription(playlist.id)
                                    working = false
                                }
                            } label: {
                                HStack {
                                    Text(playlist.name).foregroundStyle(Brand.textPrimary)
                                    Spacer()
                                    Text(playlist.kind.displayTarget)
                                        .font(.caption).foregroundStyle(Brand.textMuted)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Brand.surfaceHover, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .disabled(connecting)
                        }
                    }
                    .padding(16)
                    .frame(width: 440)
                    .background(Brand.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Brand.border))

                    Text("or sign in with a different login").font(.caption).foregroundStyle(Brand.textMuted)
                }

                VStack(alignment: .leading, spacing: 12) {
                    field("Server", prompt: "http://host:port", text: $server)
                    field("Username", prompt: "username", text: $username)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Password").font(.caption).foregroundStyle(Brand.textMuted)
                        SecureField("password", text: $password)
                            .textFieldStyle(.roundedBorder)
                    }

                    Toggle("Remember me in the Keychain", isOn: $remember)
                        .toggleStyle(.checkbox)
                        .foregroundStyle(Brand.textMuted)

                    if let banner = model.banner {
                        Label(banner, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(Brand.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        working = true
                        Task {
                            await model.signIn(server: server, username: username,
                                               password: password, remember: remember)
                            working = false
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if connecting { ProgressView().controlSize(.small) }
                            Text(connecting ? "Signing in…" : "Sign In").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.orange)
                    .keyboardShortcut(.defaultAction)
                    .disabled(server.isEmpty || username.isEmpty || password.isEmpty || connecting)
                }
                .padding(24)
                .frame(width: 440)
                .background(Brand.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Brand.border))

                Text("Credentials are stored only in the macOS Keychain. This app ships with no channels, playlists or provider addresses.")
                    .font(.caption).foregroundStyle(Brand.textMuted)
                    .multilineTextAlignment(.center).frame(width: 460)

                Spacer(minLength: 0)
            }
            .padding(40)
        }
    }

    @ViewBuilder
    private func field(_ label: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(Brand.textMuted)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
        }
    }
}

// MARK: - Main

struct MainView: View {
    @EnvironmentObject private var model: AppModel

    // Remember the last view across launches.
    @State private var viewMode: AppViewMode =
        AppViewMode(rawValue: UserDefaults.standard.string(forKey: "jabcorptv.viewMode") ?? "") ?? .list

    var body: some View {
        NavigationSplitView {
            SidebarView()
                // Wider than before: the rail (52pt, fixed) now sits alongside the category
                // panel rather than inside it, so the same panel content needs the same room
                // plus the rail's own width.
                .navigationSplitViewColumnWidth(min: 290, ideal: 320, max: 400)
        } detail: {
            Group {
                if viewMode == .guide {
                    // The guide is a full-bleed surface with a floating preview, the way
                    // TiviMate does it, rather than a third narrow column.
                    ContentColumn(mode: $viewMode)
                } else {
                    HSplitView {
                        ContentColumn(mode: $viewMode)
                            .frame(minWidth: 320, idealWidth: 460)
                        PlayerPaneView()
                            .frame(minWidth: 380)
                    }
                }
            }
            // The failure message belongs to the window, not to the player pane: while the guide is
            // open that pane is not on screen at all, so a channel that would not play produced no
            // visible message anywhere. It arrives as a safe-area inset rather than by wrapping the
            // pane in a VStack. Wrapping it re-laid-out the guide and pushed the sticky channel
            // column clean out of view — pixel forensics found the column's content simply absent,
            // including its fixed-size 190x26 header rectangle, with the pane's content drawn about
            // one toolbar-height above where it belonged. An inset shows the banner without
            // touching the pane's own geometry.
            .safeAreaInset(edge: .top, spacing: 0) {
                if let banner = model.banner {
                    HStack(alignment: .top, spacing: 8) {
                        Label(banner, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(Brand.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        // The message ends by telling the user to try Retry, and Retry used to
                        // exist only inside the player pane — which guide mode never shows, so the
                        // advice could not be followed in the pane that gave it.
                        Button("Retry") { model.retryPlayback() }
                            .buttonStyle(.bordered)
                        Button("Stop") { model.stopPlayback() }
                            .buttonStyle(.bordered)
                        Button {
                            model.dismissBanner()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Brand.orange)
                        .help("Dismiss")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.orange.opacity(0.12))
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                BrandMark(size: 18).padding(.trailing, 4)
            }
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $viewMode) {
                    ForEach(AppViewMode.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .onChange(of: viewMode) { new in
                    UserDefaults.standard.set(new.rawValue, forKey: "jabcorptv.viewMode")
                }
            }
            ToolbarItem(placement: .status) {
                Text(model.statusLine).font(.caption).foregroundStyle(Brand.textMuted)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.loadCatalog() } } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .help("Reload the channel list from the provider")
            }
            ToolbarItem(placement: .primaryAction) { AccountMenu() }
        }
    }
}

struct AccountMenu: View {
    @EnvironmentObject private var model: AppModel
    @State private var showSubscriptions = false

    var body: some View {
        Menu {
            if let account = model.account {
                Text("\(account.userInfo.username) @ \(model.portalHost)")
                Text("Status: \(account.userInfo.status)")
                Text("Expires: \(account.userInfo.expiryText)")
                Text(model.connectionText)
                if account.serverInfo.isXtreamUI {
                    Text("Panel: Xtream UI \(account.serverInfo.version)")
                }
                Divider()
            }
            Button("Reload channel list") { Task { await model.loadCatalog() } }
            Button("Reload TV guide") { Task { await model.loadGuide(force: true) } }
            Divider()
            Button("Manage Subscriptions…") { showSubscriptions = true }
            Divider()
            Button("Sign Out", role: .destructive) { model.signOut() }
        } label: {
            Label("Account", systemImage: "person.crop.circle")
        }
        .sheet(isPresented: $showSubscriptions) { SubscriptionsView() }
    }
}

// MARK: - Subscriptions (switching between saved providers)

struct SubscriptionsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false
    @State private var switching: PlaylistID?
    @State private var pendingRemoval: Playlist?

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.subscriptions) { playlist in
                    HStack(spacing: 10) {
                        Image(systemName: playlist.id == model.activeSubscriptionID
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(playlist.id == model.activeSubscriptionID
                                             ? Brand.orange : Brand.textMuted.opacity(0.4))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playlist.name).font(.system(size: 13, weight: .medium))
                            Text(playlist.kind.displayTarget)
                                .font(.system(size: 11)).foregroundStyle(Brand.textMuted)
                        }
                        Spacer()
                        if switching == playlist.id {
                            ProgressView().controlSize(.small)
                        }
                        Button(role: .destructive) { pendingRemoval = playlist } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Brand.textMuted)
                        .help("Remove this subscription")
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard playlist.id != model.activeSubscriptionID, switching == nil else { return }
                        switching = playlist.id
                        Task {
                            await model.switchSubscription(playlist.id)
                            switching = nil
                        }
                    }
                }
                if model.subscriptions.isEmpty {
                    Text("No subscriptions saved yet.").foregroundStyle(Brand.textMuted)
                }
            }
            .navigationTitle("Subscriptions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: { Label("Add", systemImage: "plus") }
                }
            }
        }
        .frame(width: 420, height: 380)
        .sheet(isPresented: $showAdd) { AddSubscriptionView() }
        .alert("Remove \(pendingRemoval?.name ?? "this subscription")?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        )) {
            Button("Remove", role: .destructive) {
                if let id = pendingRemoval?.id { model.removeSubscription(id) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("Its saved login will be forgotten. This can't be undone.")
        }
    }
}

struct AddSubscriptionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var working = false
    @State private var errorText: String?
    @State private var switchNow = true

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name (optional)", text: $name)
                TextField("Server", text: $server, prompt: Text("http://host:port"))
                    .autocorrectionDisabled()
                TextField("Username", text: $username)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                Toggle("Switch to it after adding", isOn: $switchNow)
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(Brand.orange)
                }
            }
            .padding()
            .navigationTitle("Add Subscription")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(working ? "Checking…" : "Add") { Task { await add() } }
                        .disabled(working || server.isEmpty || username.isEmpty || password.isEmpty)
                }
            }
        }
        .frame(width: 380, height: 280)
    }

    private func add() async {
        working = true
        errorText = nil
        let result = await model.addSubscription(name: name, server: server,
                                                  username: username, password: password)
        working = false
        let newID: PlaylistID
        switch result {
        case .failure(let message):
            errorText = message
            return
        case .success(let id):
            newID = id
        }
        if switchNow {
            await model.switchSubscription(newID)
        }
        dismiss()
    }
}

// MARK: - Sidebar
//
// Two levels, matching a TiviMate reference the owner photographed: a narrow icon rail
// picks the content kind (Live / Movies / TV Shows), and a second panel lists that kind's
// own categories. The two used to be one flat list with every section mixed together.

struct SidebarView: View {
    var body: some View {
        HStack(spacing: 0) {
            SidebarRail()
            Divider().overlay(Brand.border)
            SidebarCategoryPanel()
        }
    }
}

struct SidebarRail: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 6) {
            BrandMark(size: 24).padding(.top, 12).padding(.bottom, 4)
            railButton(.live, systemImage: "tv", help: "Live TV")
            // Hidden entirely when the account carries none, same as the sections they used
            // to be: most providers never show these two tabs at all.
            if !model.vodCategories.isEmpty {
                railButton(.movies, systemImage: "film", help: "Movies")
            }
            if !model.seriesCategories.isEmpty {
                railButton(.series, systemImage: "tv.and.mediabox", help: "TV Shows")
            }
            Spacer(minLength: 0)
            Button(action: openSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 16))
                    .frame(width: 36, height: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Brand.textMuted)
            .padding(.bottom, 12)
            .help("Settings")
        }
        .frame(width: 52)
        .background(Brand.surfaceRaised)
    }

    private func railButton(_ section: SidebarSection, systemImage: String, help: String) -> some View {
        let active = model.sidebarSection == section
        return Button { model.selectSidebarSection(section) } label: {
            Image(systemName: systemImage)
                .font(.system(size: 17))
                .frame(width: 38, height: 34)
                .background(active ? Brand.orange.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(active ? Brand.orange : Brand.textMuted)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The app targets a macOS 13 floor; `openSettings` (the SwiftUI environment action) is
    /// 14+, so the gear button uses the classic selector AppKit has honoured since Settings
    /// scenes existed, rather than raising the deployment target for one button.
    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

struct SidebarCategoryPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // One List whose ROWS change with the active tab, not three separate Lists swapped by a
        // switch. The three-List version tore down and rebuilt the whole NSTableView-backed List
        // on every tab change — exactly the transition that has produced "reentrant operation in
        // its NSTableView delegate" warnings elsewhere in this app — and the owner hit it:
        // switching to TV Shows left the panel blank and unscrollable, Movies/Live TV included,
        // because the List itself was mid-teardown, not because their rows were ever removed.
        List(selection: $model.selectedCategoryID) {
            switch model.sidebarSection {
            case .live: liveRows
            case .movies: moviesRows
            case .series: seriesRows
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(Brand.appName)
        .safeAreaInset(edge: .top, spacing: 0) {
            Text(sectionTitle)
                .font(.headline)
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                if let account = model.account {
                    Text(account.userInfo.expiryText).font(.caption2).foregroundStyle(Brand.textMuted)
                    Text(model.connectionText).font(.caption2).foregroundStyle(Brand.textMuted)
                    if model.lockedChannelCount > 0 {
                        Text("\(model.lockedChannelCount) channels locked")
                            .font(.caption2).foregroundStyle(Brand.orange)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private var sectionTitle: String {
        switch model.sidebarSection {
        case .live: return "Live TV"
        case .movies: return "Movies"
        case .series: return "TV Shows"
        }
    }

    @ViewBuilder private var liveRows: some View {
        Section {
            Label("Favourites (\(model.favouriteCount))", systemImage: "star.fill")
                .tag(CatalogSelection.favouritesID)
            Label("Recently watched", systemImage: "clock")
                .tag(CatalogSelection.recentsID)
            Label("All Channels (\(model.channels.count))", systemImage: "rectangle.stack")
                .tag(AppModel.allCategoryID)
        }
        Section("Provider Categories") {
            ForEach(visibleCategories) { category in
                HStack(spacing: 6) {
                    Label(category.name, systemImage: "square.grid.2x2")
                    if model.lockedCategoryIDs.contains(category.id) {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(Brand.orange)
                    }
                }
                .tag(category.id)
            }
        }
    }

    @ViewBuilder private var moviesRows: some View {
        Label("All Movies (\(model.vodStreams.count))", systemImage: "film")
            .tag(CatalogSelection.vodAllID)
        ForEach(model.vodCategories) { category in
            Label(category.name, systemImage: "film")
                .tag(CatalogSelection.vodPrefix + category.id)
        }
    }

    @ViewBuilder private var seriesRows: some View {
        Label("All TV Shows (\(model.seriesList.count))", systemImage: "tv")
            .tag(CatalogSelection.seriesAllID)
        ForEach(model.seriesCategories) { category in
            Label(category.name, systemImage: "tv")
                .tag(CatalogSelection.seriesPrefix + category.id)
        }
    }

    private var visibleCategories: [ChannelCategory] {
        let hidden = Set(model.settings.data.hiddenCategoryIDs)
        var visible = model.categories.filter { !hidden.contains($0.id) }
        if model.settings.data.hideEmptyCategories {
            let populated = model.categoryIDsWithChannels
            visible = visible.filter { populated.contains($0.id) }
        }
        return visible
    }
}

// MARK: - Content

struct ContentColumn: View {
    @EnvironmentObject private var model: AppModel
    @Binding var mode: AppViewMode

    var body: some View {
        Group {
            if let locked = lockedSelection {
                ParentalGateView(categoryName: locked)
            } else if model.selectedCategoryID.hasPrefix(CatalogSelection.vodPrefix) {
                MovieListView()
            } else if model.selectedCategoryID.hasPrefix(CatalogSelection.seriesPrefix) {
                SeriesListView()
            } else if mode == .guide {
                GuideView()
            } else {
                ChannelListView()
            }
        }
        .background(Brand.surface)
    }

    private var lockedSelection: String? {
        guard model.settings.data.parentalEnabled,
              !model.parentalUnlocked,
              model.lockedCategoryIDs.contains(model.selectedCategoryID)
        else { return nil }
        return model.categoryName(for: model.selectedCategoryID)
    }
}

struct ParentalGateView: View {
    @EnvironmentObject private var model: AppModel
    let categoryName: String

    @State private var pin = ""
    @State private var wrong = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(Brand.orange)
            Text("\(categoryName) is locked")
                .font(.headline)
            Text("Enter your PIN to show this category for the rest of the session.")
                .font(.callout).foregroundStyle(Brand.textMuted)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
            SecureField("PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .onSubmit(unlock)
            if wrong {
                Text("That PIN does not match.").font(.caption).foregroundStyle(Brand.orange)
            }
            Button("Unlock", action: unlock)
                .buttonStyle(.borderedProminent).tint(Brand.orange)
                .disabled(pin.isEmpty)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unlock() {
        if pin == model.settings.data.parentalPIN {
            model.parentalUnlocked = true
            model.settingsChanged()
            wrong = false
        } else {
            wrong = true
        }
        pin = ""
    }
}

// MARK: - Channel list

struct ChannelListView: View {
    @EnvironmentObject private var model: AppModel

    // Selection is held locally and acted on in `onChange`. Mutating model state
    // from inside the selection binding is reentrant inside NSTableView's
    // delegate and will be an assert rather than a warning in a future macOS.
    @State private var selection: Int?

    var body: some View {

        List(selection: $selection) {
            ForEach(model.visibleChannels) { channel in
                ChannelRow(
                    channel: channel,
                    isPlaying: model.selectedChannel?.id == channel.id,
                    isFavourite: model.favourites.isFavourite(channel.streamID),
                    current: model.currentProgramme(for: channel),
                    next: model.nextProgramme(for: channel),
                    showNumber: model.settings.data.showChannelNumbers,
                    showLogo: model.settings.data.showLogos,
                    showCatchUp: model.settings.data.showCatchUpBadge,
                    compact: model.settings.data.compactRows,
                    onToggleFavourite: { model.toggleFavourite(channel) }
                )
                .tag(channel.id)
            }
        }
        .onChange(of: selection) { newValue in
            guard let newValue,
                  let channel = model.visibleChannels.first(where: { $0.id == newValue })
            else { return }
            // Hop one main-actor turn. Starting playback mutates state the rows
            // depend on, and doing that inside NSTableView's selection update is
            // a reentrant operation (a warning now, an assert later).
            Task { @MainActor in model.play(channel) }
        }
        .onAppear { selection = model.selectedChannel?.id }
        // The model changing is not the same as the list redrawing, and a user cannot tell the
        // difference from the outside. This line is the view layer reporting for itself.
        .onChange(of: model.visibleChannels.count) { count in
            model.writeGuideDiagnostics("channel list redrew: \(count) shown")
        }
        .listStyle(.inset)
        .searchable(text: $model.searchText, prompt: "Search channels")
        .overlay {
            if model.visibleChannels.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                    Text(emptyTitle).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(navigationTitle)
        .navigationSubtitle("\(model.visibleChannels.count) shown")
    }

    private var emptyTitle: String {
        if !model.searchText.isEmpty { return "No matches" }
        switch model.selectedCategoryID {
        case CatalogSelection.favouritesID: return "No favourites yet — click a star"
        case CatalogSelection.recentsID: return "Nothing watched yet"
        default: return "No channels"
        }
    }

    private var navigationTitle: String {
        switch model.selectedCategoryID {
        case AppModel.allCategoryID: return "All Channels"
        case CatalogSelection.favouritesID: return "Favourites"
        case CatalogSelection.recentsID: return "Recently watched"
        default: return model.categoryName(for: model.selectedCategoryID)
        }
    }
}

struct ChannelRow: View {
    let channel: Channel
    let isPlaying: Bool
    let isFavourite: Bool
    let current: XMLTVProgramme?
    let next: XMLTVProgramme?
    let showNumber: Bool
    let showLogo: Bool
    let showCatchUp: Bool
    let compact: Bool
    let onToggleFavourite: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if showLogo {
                AsyncImage(url: channel.iconURL.flatMap(URL.init(string:))) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Image(systemName: "tv").foregroundStyle(Brand.textMuted.opacity(0.5))
                }
                .frame(width: 40, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if showNumber, channel.number > 0 {
                        Text("\(channel.number)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Brand.textMuted)
                    }
                    Text(channel.name)
                        .font(.system(size: 12, weight: isPlaying ? .semibold : .regular))
                        .foregroundStyle(isPlaying ? Brand.orange : Brand.textPrimary)
                        .lineLimit(1)
                    if showCatchUp && channel.hasArchive {
                        Label("\(channel.archiveDays)d", systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 9))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Brand.tealLifted.opacity(0.25), in: Capsule())
                            .foregroundStyle(Brand.tealLifted)
                            .help("\(channel.archiveDays)-day catch-up available")
                    }
                }
                if !compact, let current {
                    Text("\(GuideFormat.range(current.start, current.stop))  \(current.title)")
                        .font(.system(size: 10)).foregroundStyle(Brand.textMuted).lineLimit(1)
                } else if let next, compact {
                    Text("Next: \(next.title)").font(.system(size: 10))
                        .foregroundStyle(Brand.textMuted).lineLimit(1)
                }
                if let current {
                    ProgressView(value: progress(of: current)).progressViewStyle(.linear).frame(height: 2)
                }
            }

            Spacer(minLength: 6)

            if isPlaying {
                Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(Brand.orange)
            }

            Button(action: onToggleFavourite) {
                Image(systemName: isFavourite ? "star.fill" : "star")
                    .foregroundStyle(isFavourite ? Brand.orange : Brand.textMuted.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help(isFavourite ? "Remove from favourites" : "Add to favourites")
        }
        .padding(.vertical, compact ? 2 : 4)
        .contentShape(Rectangle())
    }

    private func progress(of programme: XMLTVProgramme) -> Double {
        let span = programme.stop.timeIntervalSince(programme.start)
        guard span > 0 else { return 0 }
        return min(max(Date().timeIntervalSince(programme.start) / span, 0), 1)
    }
}

// MARK: - Movies (VOD)

struct MovieListView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            ForEach(model.filteredVOD) { movie in
                MovieRow(movie: movie, isPlaying: model.nowPlayingIsMedia && model.nowPlayingTitle == movie.name)
                    .contentShape(Rectangle())
                    .onTapGesture { model.playMovie(movie) }
            }
        }
        .listStyle(.inset)
        .searchable(text: $model.searchText, prompt: "Search movies")
        .overlay {
            if model.filteredVOD.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
                    Text(model.searchText.isEmpty ? "No movies" : "No matches").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Movies")
        .navigationSubtitle("\(model.filteredVOD.count) shown")
    }
}

struct MovieRow: View {
    let movie: VODStream
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: movie.iconURL.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "film").foregroundStyle(Brand.textMuted.opacity(0.5))
            }
            .frame(width: 34, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(movie.name)
                    .font(.system(size: 12, weight: isPlaying ? .semibold : .regular))
                    .foregroundStyle(isPlaying ? Brand.orange : Brand.textPrimary)
                    .lineLimit(1)
                if let rating = movie.rating, !rating.isEmpty {
                    Label(rating, systemImage: "star.fill")
                        .font(.system(size: 10)).foregroundStyle(Brand.textMuted)
                }
            }
            Spacer(minLength: 6)
            if isPlaying {
                Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(Brand.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Series (TV shows)

struct SeriesListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var openSeries: SeriesSummary?

    var body: some View {
        List {
            ForEach(model.filteredSeries) { series in
                SeriesRow(series: series)
                    .contentShape(Rectangle())
                    .onTapGesture { openSeries = series }
            }
        }
        .listStyle(.inset)
        .searchable(text: $model.searchText, prompt: "Search TV shows")
        .overlay {
            if model.filteredSeries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tv").font(.largeTitle).foregroundStyle(.secondary)
                    Text(model.searchText.isEmpty ? "No TV shows" : "No matches").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("TV Shows")
        .navigationSubtitle("\(model.filteredSeries.count) shown")
        .sheet(item: $openSeries) { series in
            SeriesEpisodesView(series: series)
        }
    }
}

struct SeriesRow: View {
    let series: SeriesSummary

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: series.iconURL.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "tv").foregroundStyle(Brand.textMuted.opacity(0.5))
            }
            .frame(width: 34, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(series.name).font(.system(size: 12)).lineLimit(1)
                if let rating = series.rating, !rating.isEmpty {
                    Label(rating, systemImage: "star.fill")
                        .font(.system(size: 10)).foregroundStyle(Brand.textMuted)
                }
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Brand.textMuted.opacity(0.6))
        }
        .padding(.vertical, 4)
    }
}

/// A season/episode picker fetched on demand: `get_series_info` is one request per series, and
/// nothing needs it until the user actually opens that series.
struct SeriesEpisodesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let series: SeriesSummary

    @State private var episodesBySeason: [Int: [SeriesEpisode]] = [:]
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Loading episodes…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if episodesBySeason.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "questionmark.folder").font(.largeTitle).foregroundStyle(.secondary)
                        Text("This provider sent no episodes for this show.").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(episodesBySeason.keys.sorted(), id: \.self) { season in
                            Section("Season \(season)") {
                                ForEach(episodesBySeason[season] ?? []) { episode in
                                    Button {
                                        model.playEpisode(episode, of: series)
                                        dismiss()
                                    } label: {
                                        HStack {
                                            Text("E\(episode.episodeNumber)")
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundStyle(Brand.textMuted)
                                                .frame(width: 32, alignment: .leading)
                                            Text(episode.title).lineLimit(1)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(series.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .frame(width: 420, height: 480)
        .task {
            episodesBySeason = await model.fetchEpisodes(seriesID: series.seriesID)
            loading = false
        }
    }
}

// MARK: - Player

struct PlayerPaneView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PlayerSurface(player: model.player).background(.black)

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(model.nowPlayingTitle.isEmpty ? "Nothing playing" : model.nowPlayingTitle)
                            .font(.headline).lineLimit(1)
                        if model.isCatchUp {
                            Text("CATCH-UP")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Brand.tealLifted.opacity(0.25), in: Capsule())
                                .foregroundStyle(Brand.tealLifted)
                        }
                    }
                    Text(model.nowPlayingDetail.isEmpty
                         ? (model.selectedChannel == nil && !model.nowPlayingIsMedia
                            ? "Pick a channel from the list." : "")
                         : model.nowPlayingDetail)
                        .font(.callout).foregroundStyle(Brand.textMuted).lineLimit(2)
                    if model.playbackFailed, let channel = model.selectedChannel {
                        HStack(spacing: 8) {
                            Button("Retry") { model.retryPlayback() }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                            Button("Play in VLC") { model.openInVLC(channel) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                        .padding(.top, 2)
                    } else if model.playbackFailed, model.nowPlayingIsMedia {
                        HStack(spacing: 8) {
                            Button("Retry") { model.retryMedia() }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                            Button("Play in VLC") { model.openMediaInVLC() }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                        .padding(.top, 2)
                    }
                    if let channel = model.selectedChannel,
                       let current = model.currentProgramme(for: channel) {
                        Text(current.detail)
                            .font(.caption).foregroundStyle(Brand.textMuted)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if let channel = model.selectedChannel {
                    if model.isCatchUp {
                        Button { model.backToLive() } label: {
                            Label("Back to Live", systemImage: "dot.radiowaves.left.and.right")
                        }
                        .buttonStyle(.borderedProminent).tint(Brand.orange)
                    }
                    Button {
                        NSApp.keyWindow?.toggleFullScreen(nil)
                    } label: {
                        Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.bordered)
                    .help("Full screen video (⌃⌘F). Esc exits.")
                    Button("Open in VLC") { model.openInVLC(channel) }
                        .buttonStyle(.bordered)
                        .help("Play the raw .ts transport stream in an external player")
                    Button("Stop") { model.stopPlayback() }.buttonStyle(.bordered)
                } else if model.nowPlayingIsMedia {
                    Button {
                        NSApp.keyWindow?.toggleFullScreen(nil)
                    } label: {
                        Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.bordered)
                    .help("Full screen video (⌃⌘F). Esc exits.")
                    Button("Open in VLC") { model.openMediaInVLC() }
                        .buttonStyle(.bordered)
                    Button("Stop") { model.stopPlayback() }.buttonStyle(.bordered)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.surfaceRaised)

            if let banner = model.banner {
                Label(banner, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Brand.orange)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.orange.opacity(0.10))
            }
        }
        .navigationTitle(model.selectedChannel?.name ?? "Player")
    }
}

/// What the whole window becomes in full screen. AVPlayerView already brings the
/// native control bar, PiP and the system's own full-screen exit; this adds the
/// channel identity and the catch-up escape hatch on top of a gradient so the text
/// stays readable over bright video.
struct FullScreenPlayerView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showOverlay = true

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            PlayerSurface(player: model.player)

            if showOverlay {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 9) {
                        BrandMark(size: 20)
                        Text(model.nowPlayingTitle.isEmpty ? "Nothing playing" : model.nowPlayingTitle)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                        if model.isCatchUp {
                            Text("CATCH-UP")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Brand.tealLifted.opacity(0.35), in: Capsule())
                                .foregroundStyle(.white)
                        }
                        Spacer()
                        if model.isCatchUp {
                            Button { model.backToLive() } label: {
                                Label("Back to Live", systemImage: "dot.radiowaves.left.and.right")
                            }
                            .buttonStyle(.borderedProminent).tint(Brand.orange)
                        }
                        Button {
                            NSApp.keyWindow?.toggleFullScreen(nil)
                        } label: {
                            Label("Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left")
                        }
                        .buttonStyle(.bordered)
                        .help("Esc also exits")
                    }
                    if !model.nowPlayingDetail.isEmpty {
                        Text(model.nowPlayingDetail)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0.0)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea(edges: .top)
                )
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeInOut(duration: 0.25)) { showOverlay = inside }
        }
    }
}

/// AVPlayerView in floating-controls mode gives us the full native control bar,
/// picture-in-picture and full screen for free.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.allowsPictureInPicturePlayback = true
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
