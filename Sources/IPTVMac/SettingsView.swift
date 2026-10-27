import SwiftUI
import AppKit
import IPTVMacCore

/// Settings, grouped the way TiviMate groups them. Only switches that actually
/// change behaviour are here — nothing is included to look complete.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pinEntry = ""
    @State private var newPIN = ""
    @State private var backupText = ""
    @State private var backupNotice = ""
    @State private var catchUpResult = ""

    var body: some View {
        TabView {
            appearance.tabItem { Label("Appearance", systemImage: "paintbrush") }
            playback.tabItem { Label("Playback", systemImage: "play.rectangle") }
            guideTab.tabItem { Label("EPG", systemImage: "calendar") }
            catchUpTab.tabItem { Label("Catch-up", systemImage: "clock.arrow.circlepath") }
            channelsTab.tabItem { Label("Channels", systemImage: "list.bullet") }
            parental.tabItem { Label("Parental", systemImage: "lock") }
            account.tabItem { Label("Account", systemImage: "person.crop.circle") }
            backup.tabItem { Label("Backup", systemImage: "externaldrive") }
            about.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 460)
        .onAppear { backupText = model.settings.exportJSON() }
    }

    private var bindable: AppSettings { model.settings }

    /// macOS 13 replacement for `$settings.data.foo` (the `@Bindable` projection is 14.0+).
    /// Writes go through AppSettings.data so the existing `didSet { persist() }` still fires.
    private func binding<T>(_ keyPath: WritableKeyPath<SettingsData, T>) -> Binding<T> {
        Binding(get: { model.settings.data[keyPath: keyPath] },
                // Persisting is not the same as applying. `data` has a didSet that writes to
                // UserDefaults, so every one of these controls already survived a relaunch — but
                // nothing told the model to rebuild what it derives from those values. Six controls
                // looked live and were not: sort order, hidden categories, parental controls and its
                // keywords, the guide's time offset, and Import. Each took effect only when some
                // *other* action happened to trigger a recompute. Wire the notification at the one
                // point every one of them passes through.
                set: { model.settings.data[keyPath: keyPath] = $0; model.settingsChanged() })
    }

    // MARK: Appearance

    @ViewBuilder private var appearance: some View {
                Form {
            Section("Theme") {
                Picker("Appearance", selection: binding(\.appearance)) {
                    ForEach(AppearanceChoice.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Accent", selection: binding(\.accent)) {
                    ForEach(AccentChoice.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Channel list") {
                Toggle("Compact rows", isOn: binding(\.compactRows))
                Toggle("Show channel numbers", isOn: binding(\.showChannelNumbers))
                Toggle("Show channel logos", isOn: binding(\.showLogos))
            }
            Section("Sort") {
                Picker("Sort channels by", selection: binding(\.sortOrder)) {
                    ForEach(ChannelSort.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Playback

    @ViewBuilder private var playback: some View {
        let settings = model.settings
        Form {
            Section("Stream") {
                Picker("Preferred format", selection: binding(\.preferredFormat)) {
                    ForEach(StreamFormat.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("Providers advertise m3u8, ts and rtmp. macOS AVPlayer plays HLS natively and cannot play raw MPEG-TS over HTTP, so HLS is the right default.")
                    .font(.caption).foregroundStyle(Brand.textMuted)
            }
            Section("Behaviour") {
                Toggle("Stop the previous stream before starting a new one", isOn: binding(\.stopPreviousOnZap))
                Toggle("Resume the last channel on launch", isOn: binding(\.resumeLastChannel))
            }
            Section("Fallback player") {
                TextField("Path to VLC.app", text: binding(\.openInVLCPath))
                Button("Test — reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: settings.data.openInVLCPath)])
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: EPG

    @ViewBuilder private var guideTab: some View {
        let settings = model.settings
        Form {
            Section("Window") {
                Stepper("Hours ahead: \(settings.data.guideHoursAhead)",
                        value: binding(\.guideHoursAhead), in: 2...48)
                Stepper("Minutes back: \(settings.data.guideMinutesBack)",
                        value: binding(\.guideMinutesBack), in: 0...240, step: 15)
            }
            Section("Data") {
                Stepper("Refresh every \(settings.data.guideRefreshMinutes) min",
                        value: binding(\.guideRefreshMinutes), in: 5...240, step: 5)
                Stepper("Time offset: \(settings.data.epgOffsetMinutes) min",
                        value: binding(\.epgOffsetMinutes), in: -720...720, step: 15)
                Text("The offset shifts every programme. Some providers publish the guide in another timezone; use this when everything is a fixed number of hours out.")
                    .font(.caption).foregroundStyle(Brand.textMuted)
            }
            Section {
                Toggle("Show progress inside the current programme", isOn: binding(\.showGuideProgress))
                Toggle("Show the live preview and programme details bar above the guide",
                       isOn: binding(\.showGuidePreview))
                Toggle("Auto-align the guide with the current time", isOn: binding(\.autoAlignGuide))
                    .help("Some providers publish the guide on a different clock, which "
                          + "leaves the grid empty. This measures the shift and corrects it.")
                HStack {
                    Text(model.guideStatus).font(.caption).foregroundStyle(Brand.textMuted)
                    Spacer()
                    Button("Reload guide") { Task { await model.loadGuide(force: true) } }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Channels

    @ViewBuilder private var channelsTab: some View {
        let settings = model.settings
        VStack(alignment: .leading, spacing: 0) {
            Toggle("Hide categories with no channels", isOn: binding(\.hideEmptyCategories))
                .padding([.horizontal, .top], 14)
            Text("Providers list categories they carry nothing in. This drops them from the sidebar.")
                .font(.caption).foregroundStyle(Brand.textMuted)
                .padding(.horizontal, 14).padding(.bottom, 8)
            Text("Hidden categories (\(settings.data.hiddenCategoryIDs.count))")
                .font(.headline).padding([.horizontal, .top], 14).padding(.bottom, 6)
            Text("Unticked categories disappear from the sidebar and the guide.")
                .font(.caption).foregroundStyle(Brand.textMuted).padding(.horizontal, 14).padding(.bottom, 8)
            List {
                ForEach(model.categories) { category in
                    Toggle(isOn: Binding(
                        get: { !settings.data.hiddenCategoryIDs.contains(category.id) },
                        set: { shown in
                            var hidden = settings.data.hiddenCategoryIDs
                            if shown { hidden.removeAll { $0 == category.id } }
                            else if !hidden.contains(category.id) { hidden.append(category.id) }
                            // This row builds its own Binding instead of going through the
                            // `binding(_:)` helper above (its set logic adds/removes one id from
                            // an array per row, not a flat keypath replace) — which meant it was
                            // never wired to `settingsChanged()`. The sidebar's own category list
                            // reads `hiddenCategoryIDs` as a live computed property, so unticking
                            // a category disappeared it from the sidebar correctly, but
                            // `filteredChannels` is a CACHE only refreshed inside
                            // `recomputeFilter()` — exactly the "toggled and nothing happened"
                            // bug class this file's whole `binding()` helper exists to close,
                            // just missed for this one control.
                            settings.data.hiddenCategoryIDs = hidden
                            model.settingsChanged()
                        }
                    )) {
                        Text(category.name)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: Catch-up

    @ViewBuilder private var catchUpTab: some View {
                Form {
            Section("This provider") {
                LabeledContent("Channels offering catch-up",
                               value: "\(model.catchUpChannelCount) of \(model.channels.count)")
                if model.catchUpSupported {
                    Text("Past programmes on those channels play from the archive. Click one in the guide.")
                        .font(.caption).foregroundStyle(Brand.textMuted)
                } else {
                    Text("No channel advertises an archive, so past programmes cannot be played. "
                         + "Catch-up is something a provider enables and usually charges for — if you want "
                         + "it, ask yours to turn on catch-up (timeshift) for your line, or use a portal "
                         + "that includes it. The player is ready for it either way.")
                        .font(.caption).foregroundStyle(Brand.orange)
                }
                HStack {
                    Button("Test the archive") { Task { catchUpResult = await model.probeCatchUp() } }
                    Spacer()
                    Text(catchUpResult).font(.caption).foregroundStyle(Brand.textMuted)
                        .lineLimit(3).multilineTextAlignment(.trailing).textSelection(.enabled)
                }
            }
            Section("Playing") {
                Toggle("Start programmes already under way from the beginning",
                       isOn: binding(\.startLiveFromBeginning))
                Text("Applies only to channels that carry an archive. Otherwise clicking a programme joins it live.")
                    .font(.caption).foregroundStyle(Brand.textMuted)
            }
            Section("Channels") {
                Toggle("Show the archive-days badge on channels", isOn: binding(\.showCatchUpBadge))
                Text("The badge shows how many days of archive the provider claims for that channel.")
                    .font(.caption).foregroundStyle(Brand.textMuted)
            }
            Section("How it works") {
                Text("Past programmes in the guide are clickable when the channel has an archive, and faded when it does not.")
                    .font(.caption).foregroundStyle(Brand.textMuted)
                Text("Playback uses the provider's timeshift path, sending the programme's start time in UTC and its length in minutes.")
                    .font(.caption).foregroundStyle(Brand.textMuted)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Parental

    @ViewBuilder private var parental: some View {
        let settings = model.settings
        Form {
            Section {
                Toggle("Enable parental controls", isOn: binding(\.parentalEnabled))
                if settings.data.parentalPIN.isEmpty {
                    Text("No PIN set. Set one below — categories whose name matches the keywords will be locked.")
                        .font(.caption).foregroundStyle(Brand.orange)
                }
            }
            Section("PIN") {
                SecureField("New PIN (digits)", text: $newPIN)
                Button("Save PIN") {
                    let digits = newPIN.filter(\.isNumber)
                    if !digits.isEmpty { settings.data.parentalPIN = digits; newPIN = "" }
                }
                .disabled(newPIN.filter(\.isNumber).isEmpty)
            }
            Section("Locked categories match these keywords") {
                TextField("adult, xxx, 18+", text: binding(\.lockedCategoryKeywords))
                Text("Matched case-insensitively against the provider's category names.")
                    .font(.caption).foregroundStyle(Brand.textMuted)
            }
            Section {
                Toggle("Require the PIN to open Settings", isOn: binding(\.lockSettings))
                HStack {
                    Text(model.parentalUnlocked ? "Unlocked for this session" : "Locked")
                        .font(.caption).foregroundStyle(Brand.textMuted)
                    Spacer()
                    Button("Lock now") { model.parentalUnlocked = false }
                        .disabled(!model.parentalUnlocked)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Account

    @ViewBuilder private var account: some View {
        Form {
            if let account = model.account {
                Section("Provider") {
                    LabeledContent("Server", value: account.serverInfo.host.isEmpty ? model.portalHost : account.serverInfo.host)
                    LabeledContent("Username", value: account.userInfo.username)
                    LabeledContent("Status", value: account.userInfo.status)
                    LabeledContent("Expires", value: account.userInfo.expiryText)
                    LabeledContent("Connections", value: model.connectionText)
                    LabeledContent("Panel", value: account.serverInfo.isXtreamUI
                                   ? "Xtream UI \(account.serverInfo.version)" : account.serverInfo.version)
                }
                Section("Catalog") {
                    LabeledContent("Channels", value: "\(model.channels.count)")
                    LabeledContent("Categories", value: "\(model.categories.count)")
                    LabeledContent("Guide programmes", value: "\(model.epgProgrammeCount)")
                    LabeledContent("Allowed formats", value: account.userInfo.allowedOutputFormats.joined(separator: ", "))
                }
            } else {
                Text("Not signed in.").foregroundStyle(Brand.textMuted)
            }
            Section {
                Button("Run diagnostics") { model.runDiagnostics() }
                HStack {
                    Text(model.diagnosticsResult).font(.caption).foregroundStyle(Brand.textMuted)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.diagnosticsResult, forType: .string)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Backup

    @ViewBuilder private var backup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings, favourites and groups as JSON. Credentials are never included — those live in the Keychain only.")
                .font(.caption).foregroundStyle(Brand.textMuted)
            TextEditor(text: $backupText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 240)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.border))
            HStack {
                Button("Refresh") { backupText = model.settings.exportJSON() }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(backupText, forType: .string)
                    backupNotice = "Copied."
                }
                Button("Import") {
                    backupNotice = model.settings.importJSON(backupText) ? "Imported." : "That is not valid settings JSON."
                }
                Button("Reset to defaults", role: .destructive) {
                    model.settings.resetToDefaults(); backupText = model.settings.exportJSON()
                    backupNotice = "Reset."
                }
                Spacer()
                Text(backupNotice).font(.caption).foregroundStyle(Brand.textMuted)
            }
        }
        .padding(14)
    }

    // MARK: About

    @ViewBuilder private var about: some View {
        VStack(spacing: 14) {
            BrandLockup(width: 330)
            Text("Version \(AppInfo.version) (\(AppInfo.build))")
                .font(.caption).foregroundStyle(Brand.textMuted)
            Text("A clean-room macOS player for your own Xtream Codes subscription.\nWritten from scratch — no code, assets or strings from any third-party app.")
                .font(.callout).foregroundStyle(Brand.textMuted)
                .multilineTextAlignment(.center).frame(maxWidth: 400)
            Divider().frame(maxWidth: 400)
            VStack(alignment: .leading, spacing: 6) {
                Label("DRM-protected channels cannot play here, and no macOS app can — macOS ships FairPlay, not Widevine.", systemImage: "lock.shield")
                Label("Nothing in this app hides your connection from your provider.", systemImage: "hand.raised")
                Label("Credentials are stored only in the macOS Keychain.", systemImage: "key")
            }
            .font(.caption).foregroundStyle(Brand.textMuted)
            .frame(maxWidth: 420, alignment: .leading)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
    }
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
    }
}
