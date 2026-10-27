import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showHelp = false

    private var canSubmit: Bool {
        !server.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                VStack(alignment: .leading, spacing: 14) {
                    field("Server", prompt: "http://your-provider.com:8080", text: $server)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    field("Username", prompt: "username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Password").font(.caption).foregroundStyle(Theme.secondaryText)
                        SecureField("password", text: $password)
                            .textContentType(.password)
                            .padding(12)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                    }
                }

                Button {
                    Task { await model.connect(server: server, username: username, password: password) }
                } label: {
                    HStack {
                        Spacer()
                        Text("Sign in").fontWeight(.semibold)
                        Spacer()
                    }
                    .padding(.vertical, 14)
                    .background(Theme.orange, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
                }
                .disabled(!canSubmit)

                Text("Your subscription stays on this iPhone — it is stored in the iOS Keychain and never uploaded. OS TV has no account, no server and no telemetry.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)

                Button("Where do I find these?") { showHelp = true }
                    .font(.footnote)
            }
            .padding(24)
        }
        .background(Theme.surface.ignoresSafeArea())
        .sheet(isPresented: $showHelp) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("These are the three values your IPTV provider gave you when you subscribed: the **server** (sometimes called portal or host), your **username**, and your **password**.")
                        Text("If your provider sent you an M3U link, the server is the part before `/get.php`, and the username and password are the `username=` and `password=` values in that link.")
                        Text("OS TV ships no channels and no playlists. It plays the subscription you already pay for.")
                    }
                    .font(.callout)
                    .padding()
                }
                .navigationTitle("Signing in")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium])
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OS TV")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.orange)
            Text("Live TV and movies from your own IPTV subscription")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.top, 30)
    }

    private func field(_ label: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(Theme.secondaryText)
            TextField(prompt, text: text)
                .padding(12)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
