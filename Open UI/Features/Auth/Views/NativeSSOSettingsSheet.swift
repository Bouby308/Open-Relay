import SwiftUI

/// Sheet for configuring native SSO (system-browser / passkey) sign-in for the
/// active server, reachable directly from the login screen.
///
/// Settings → Server → Edit Server exposes the same controls, but that path is
/// only reachable while signed in. This entry point closes the loop for
/// IdP-only servers (e.g. Keycloak without local accounts) where the user must
/// sign in via SSO the very first time — before that, there is no way to turn
/// native SSO on.
struct NativeSSOSettingsSheet: View {
    var onDismiss: () -> Void

    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var enabled: Bool = false
    @State private var issuer: String = ""
    @State private var clientID: String = ""
    @State private var providerKey: String = "oidc"
    @State private var detectingIssuer = false
    @State private var detectionNote: String?

    private var activeServer: ServerConfig? { dependencies.serverConfigStore.activeServer }
    private var isConfigured: Bool { activeServer?.nativeSSO?.isConfigured ?? false }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Sign in via System Browser", isOn: $enabled)
                        .disabled(issuer.isEmpty || clientID.isEmpty)
                    TextField("Issuer — e.g. https://keycloak.example.com/realms/myrealm", text: $issuer)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Button {
                        Task { await detectIssuer() }
                    } label: {
                        HStack(spacing: Spacing.xs) {
                            if detectingIssuer {
                                ProgressView()
                            } else {
                                Image(systemName: "dot.radiowaves.left.and.right")
                            }
                            Text(detectingIssuer ? "Detecting from server…" : "Detect issuer from server")
                        }
                        .scaledFont(size: 13, weight: .medium)
                    }
                    .disabled(detectingIssuer)
                    if let detectionNote {
                        Text(detectionNote)
                            .font(.caption2)
                            .foregroundStyle(detectionSucceeded ? theme.success : theme.textTertiary)
                    }
                    TextField("Client ID (e.g. openrelay-mobile)", text: $clientID)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Provider key (default: oidc)", text: $providerKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Native SSO (Passkeys)")
                } footer: {
                    Text("Sign in through the system browser instead of the embedded web view — this enables passkey/WebAuthn and browser SSO at your identity provider, and silent session refresh via the offline_access scope. The issuer is the identity provider's URL (auto-detected from the server's SSO redirect), NOT the Open WebUI URL. Requires an OIDC public client (PKCE) with redirect URI openui://oauth-callback and the offline_access client scope enabled, and on the server: ENABLE_OAUTH_TOKEN_EXCHANGE=true plus this client ID in OAUTH_TOKEN_EXCHANGE_TRUSTED_CLIENT_IDS.")
                        .font(.caption)
                }
            }
            .navigationTitle(isConfigured ? "Native SSO: On" : "Native SSO")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
        }
        .onAppear(perform: load)
    }

    // MARK: - Load / Save / Detect

    /// Client ID falls back to the documented native-app client name, but the
    /// issuer intentionally does NOT default to the server URL — the IdP is
    /// usually on a different origin, so a wrong default silently breaks the
    /// flow. Instead an unconfigured sheet auto-detects the issuer from the
    /// server's OAuth login redirect.
    private func load() {
        guard let server = activeServer else { return }
        enabled = server.nativeSSO != nil
        issuer = server.nativeSSO?.issuerURL ?? ""
        clientID = server.nativeSSO?.clientID ?? NativeSSOSettings.defaultClientID
        providerKey = server.nativeSSO?.providerKey ?? "oidc"
        if issuer.isEmpty {
            Task { await detectIssuer() }
        }
    }

    private var detectionSucceeded: Bool {
        detectionNote?.hasPrefix("Detected") ?? false
    }

    /// Follows Open WebUI's `/oauth/{provider}/login` redirect (the same
    /// hand-off the embedded web view performs during regular SSO login) and
    /// resolves the IdP issuer via OIDC discovery — no browser UI.
    private func detectIssuer() async {
        guard let server = activeServer else { return }
        detectingIssuer = true
        detectionNote = nil
        let detected = await NativeOIDCAuthenticator.detectIssuerURL(server: server, providerKey: providerKey)
        detectingIssuer = false
        if let detected {
            issuer = detected
            detectionNote = "Detected: \(detected)"
        } else {
            detectionNote = "Could not detect the issuer from this server — enter it manually."
        }
    }

    private func save() {
        guard var config = activeServer else {
            onDismiss()
            return
        }
        let trimmedIssuer = issuer.trimmingCharacters(in: .whitespaces)
        let trimmedClientID = clientID.trimmingCharacters(in: .whitespaces)
        if enabled, !trimmedIssuer.isEmpty, !trimmedClientID.isEmpty {
            let trimmedProviderKey = providerKey.trimmingCharacters(in: .whitespaces)
            config.nativeSSO = NativeSSOSettings(
                issuerURL: trimmedIssuer,
                clientID: trimmedClientID,
                providerKey: trimmedProviderKey.isEmpty ? "oidc" : trimmedProviderKey
            )
        } else {
            config.nativeSSO = nil
            // Turning native SSO off must also drop any stored IdP refresh token.
            KeychainService.shared.deleteToken(forServer: AuthViewModel.nativeSSORefreshKey(for: config.url))
        }
        dependencies.serverConfigStore.updateServer(config)
        onDismiss()
    }
}
