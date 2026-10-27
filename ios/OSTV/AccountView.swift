import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showLog = false

    var body: some View {
        NavigationStack {
            List {
                Section("Subscription") {
                    row("Server", model.account.map { "\($0.serverInfo.host):\($0.serverInfo.port)" } ?? "—")
                    row("Status", model.account?.userInfo.status ?? "—")
                    row("Expires", model.account?.userInfo.expiryText ?? "—")
                    row("Connections", model.account.map { "\($0.userInfo.activeConnections) of \($0.userInfo.maxConnections)" } ?? "—")
                }
                Section("Loaded") {
                    row("Live channels", "\(model.channels.count)")
                    row("Categories", "\(model.categories.count)")
                    row("Movies", "\(model.movies.count)")
                }
                Section {
                    Button("View diagnostics log") { showLog = true }
                    Button("Sign out", role: .destructive) { model.signOut() }
                } footer: {
                    Text("Signing out removes the subscription from this iPhone's Keychain.")
                }
                Section {
                    Text("OS TV \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") — source at github.com/cachecowdigital/OS-TV")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.surface)
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showLog) {
                NavigationStack {
                    ScrollView {
                        Text(Log.tail(200))
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding()
                    }
                    .background(Theme.surface)
                    .navigationTitle("Diagnostics")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showLog = false }
                        }
                    }
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).foregroundStyle(Theme.secondaryText) }
    }
}
