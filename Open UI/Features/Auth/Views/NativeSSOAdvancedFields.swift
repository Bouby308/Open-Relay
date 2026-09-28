import SwiftUI

/// Advanced option for signing in through the system browser (passkeys / Safari
/// SSO at a self-hosted identity provider). Shown only inside the "Advanced"
/// sections, so the everyday sign-in screens stay unchanged.
///
/// Applies to the generic **OIDC** provider only (Keycloak, Authentik, Zitadel…).
/// Google, Microsoft and GitHub always use the regular sign-in.
struct NativeSSOAdvancedFields: View {
    @Binding var isEnabled: Bool
    @Binding var issuer: String
    @Binding var clientID: String

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Sign in via System Browser")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textPrimary)
                    Text("Passkeys & Safari SSO for self-hosted OIDC")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }
                Spacer()
                Toggle("", isOn: $isEnabled.animation(.easeInOut(duration: 0.2)))
                    .labelsHidden()
                    .tint(theme.brandPrimary)
            }

            if isEnabled {
                ModernTextField(
                    label: "Issuer URL (optional)",
                    placeholder: "Auto-detected, e.g. https://id.example.com/realms/main",
                    text: $issuer,
                    keyboardType: .URL,
                    textContentType: .URL
                )
                ModernTextField(
                    label: "Client ID",
                    placeholder: NativeSSOSettings.defaultClientID,
                    text: $clientID
                )
                Text(NativeSSOHelp.requirements)
                    .scaledFont(size: 11)
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// `Form` variant of ``NativeSSOAdvancedFields`` for Settings → Edit Server.
struct NativeSSOFormSection: View {
    @Binding var isEnabled: Bool
    @Binding var issuer: String
    @Binding var clientID: String

    var body: some View {
        Section {
            Toggle("Sign in via System Browser", isOn: $isEnabled.animation())
            if isEnabled {
                TextField("Issuer URL (auto-detected if blank)", text: $issuer)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                TextField("Client ID (\(NativeSSOSettings.defaultClientID))", text: $clientID)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        } header: {
            Text("Passkeys & System Browser Sign-In")
        } footer: {
            Text(NativeSSOHelp.requirements)
                .font(.caption)
        }
    }
}

enum NativeSSOHelp {
    static let requirements = """
    For the "SSO" (OIDC) provider only — Google, Microsoft and GitHub keep the regular sign-in. \
    Requires server setup: Open WebUI 0.8+ with ENABLE_OAUTH_TOKEN_EXCHANGE=true and this client ID in \
    OAUTH_TOKEN_EXCHANGE_TRUSTED_CLIENT_IDS, plus a public PKCE client at your identity provider with \
    redirect URI openui://oauth-callback. Your account must have signed in on the web once.
    """
}
