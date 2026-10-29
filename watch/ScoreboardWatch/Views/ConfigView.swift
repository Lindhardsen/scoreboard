import SwiftUI

/// Sign-in: server, username and password. Only the returned token is kept.
struct ConfigView: View {
    @ObservedObject var store: ScoreStore
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var signingIn = false
    @State private var error: String?

    var body: some View {
        Form {
            TextField("volley.lindhardsen.org", text: $server)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Username", text: $username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $password)
                .textContentType(.password)
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Button {
                Task { await signIn() }
            } label: {
                if signingIn { ProgressView() } else { Text("Sign in") }
            }
            .disabled(signingIn || server.isEmpty || username.isEmpty || password.isEmpty)
        }
        .navigationTitle("Scoreboard")
    }

    private func signIn() async {
        signingIn = true
        error = nil
        defer { signingIn = false }
        do {
            try await store.signIn(server: server, username: username, password: password)
            password = ""
        } catch {
            self.error = Self.message(for: error)
        }
    }

    static func message(for error: ClientError) -> String {
        switch error {
        case .invalidServer: "Enter a server address"
        case .unreachable, .badResponse, .server: "Can't reach server"
        case .wrongPassword, .unknownUser, .forbidden: "Wrong username or password"
        case .rateLimited: "Too many attempts — wait 5 minutes"
        }
    }
}
