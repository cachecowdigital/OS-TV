import SwiftUI
import AppKit
import IPTVMacCore

@main
struct OSTVApp: App {
    @StateObject private var model = AppModel()

    init() {
        // A SwiftPM executable is not a bundled app by default; make sure the
        // window comes to the front and takes focus.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup(Brand.appName) {
            RootView()
                .environmentObject(model)
                .task {
                    await model.bootstrap()
                    await model.addAndSwitchSubscriptionFromEnvironmentIfRequested()
                }
        }
        .defaultSize(width: 1360, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Playback") {
                Button("Back to Live") { model.backToLive() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(!model.isCatchUp)
                Button("Stop") { model.stopPlayback() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(model.selectedChannel == nil)
                Divider()
                Button("Open in VLC") {
                    if let channel = model.selectedChannel { model.openInVLC(channel) }
                }
                .disabled(model.selectedChannel == nil)
            }
            CommandMenu("Guide") {
                Button("Reload Guide") { Task { await model.loadGuide(force: true) } }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
        }

        Settings { SettingsGateView().environmentObject(model) }
    }
}

/// Settings can be PIN-protected. Gating the window itself (not a sheet) means the
/// stored values are never rendered before the PIN is entered.
struct SettingsGateView: View {
    @EnvironmentObject private var model: AppModel

    @State private var pin = ""
    @State private var wrong = false

    private var needsPIN: Bool {
        model.settings.data.lockSettings
            && !model.settings.data.parentalPIN.isEmpty
            && !model.parentalUnlocked
    }

    var body: some View {
        if needsPIN {
            VStack(spacing: 14) {
                Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(Brand.orange)
                Text("Settings are locked").font(.headline)
                SecureField("PIN", text: $pin)
                    .textFieldStyle(.roundedBorder).frame(width: 180)
                    .onSubmit(unlock)
                if wrong {
                    Text("That PIN does not match.").font(.caption).foregroundStyle(Brand.orange)
                }
                Button("Unlock", action: unlock)
                    .buttonStyle(.borderedProminent).tint(Brand.orange)
                    .disabled(pin.isEmpty)
            }
            .padding(40)
            .frame(width: 420, height: 300)
            .background(Brand.surface)
        } else {
            SettingsView()
        }
    }

    private func unlock() {
        if pin == model.settings.data.parentalPIN {
            model.parentalUnlocked = true
            wrong = false
        } else {
            wrong = true
        }
        pin = ""
    }
}
