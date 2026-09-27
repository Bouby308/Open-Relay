import Foundation
import AuthenticationServices
import CryptoKit
import UIKit
import os.log

// MARK: - Native SSO Settings

/// Per-server settings for the native OIDC SSO flow.
///
/// When configured, sign-in for the matching provider runs through
/// `ASWebAuthenticationSession` (the system browser service) instead of the
/// embedded WKWebView. This is what enables **passkey / WebAuthn login at the
/// identity provider** — WKWebView only offers passkeys when the app declares
/// Associated Domains for the IdP's domain (which is impossible for domains
/// you don't control, and requires an AASA file on the RP domain).
///
/// Flow: authorize (PKCE, public client) → `openui://oauth-callback?code=…`
/// → token endpoint → Open WebUI token-exchange endpoint → Open WebUI JWT.
///
/// Server prerequisites (Open WebUI env):
/// - `ENABLE_OAUTH_TOKEN_EXCHANGE=true`
/// - `OAUTH_TOKEN_EXCHANGE_TRUSTED_CLIENT_IDS` must contain ``clientID``
///   (requires an IdP with RFC 7662 introspection, e.g. Keycloak).
struct NativeSSOSettings: Codable, Hashable, Sendable {
    /// Default native-app client ID expected at the IdP.
    static let defaultClientID = "openrelay-mobile"

    /// OIDC issuer URL, e.g. `https://kc.example.com/realms/myrealm`.
    /// Discovery is performed at `{issuer}/.well-known/openid-configuration`.
    var issuerURL: String

    /// Public (native-app) OIDC client registered at the IdP with
    /// redirect URI `openui://oauth-callback` and PKCE (S256) enforced.
    var clientID: String

    /// Open WebUI provider key used in the exchange path, e.g. "oidc"
    /// for a generic OIDC provider such as Keycloak.
    var providerKey: String

    init(issuerURL: String = "", clientID: String = Self.defaultClientID, providerKey: String = "oidc") {
        self.issuerURL = issuerURL
        self.clientID = clientID
        self.providerKey = providerKey
    }

    /// Whether the settings contain everything needed to run the native flow.
    var isConfigured: Bool {
        !issuerURL.trimmingCharacters(in: .whitespaces).isEmpty &&
        !clientID.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// MARK: - Errors

enum NativeOIDCAuthError: LocalizedError {
    case notConfigured
    case invalidIssuer
    case discoveryFailed(statusCode: Int)
    case missingEndpoints
    case cancelled
    case providerError(description: String)
    case stateMismatch
    case missingAuthorizationCode
    case tokenRequestFailed(statusCode: Int, detail: String?)
    case missingAccessToken
    case missingRefreshToken
    case exchangeFailed(statusCode: Int, detail: String?)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Native SSO is not configured for this server. Set the issuer URL and client ID in Server settings."
        case .invalidIssuer:
            return "The native SSO issuer URL is invalid."
        case .discoveryFailed(let code):
            return "Could not reach the identity provider's OIDC discovery document (HTTP \(code))."
        case .missingEndpoints:
            return "The identity provider's discovery document is missing the authorize or token endpoint."
        case .cancelled:
            return "Sign-in was cancelled."
        case .providerError(let description):
            return "The identity provider rejected the sign-in: \(description)"
        case .stateMismatch:
            return "Sign-in response failed validation (possible CSRF). Please try again."
        case .missingAuthorizationCode:
            return "The identity provider did not return an authorization code."
        case .tokenRequestFailed(_, let detail):
            return "Token exchange with the identity provider failed.\(detail.map { " \($0)" } ?? "")"
        case .missingAccessToken:
            return "The identity provider returned no access token."
        case .missingRefreshToken:
            return "The identity provider did not issue a refresh token. Ensure the client allows the offline_access scope (Keycloak: client scope 'offline_access' available, 'Standard Flow Enabled' public client with PKCE)."
        case .exchangeFailed(_, let detail):
            return "Open WebUI rejected the token exchange.\(detail.map { " \($0)" } ?? "")"
        }
    }
}

// MARK: - Session result

/// Result of a successful native SSO sign-in or silent refresh.
struct NativeSSOSession: Sendable {
    /// Fresh Open WebUI session JWT — ready for `APIClient.updateAuthToken`.
    let jwt: String
    /// IdP refresh token (offline_access). Persist in the Keychain to allow
    /// silent re-exchange when the Open WebUI JWT expires. `nil` when the
    /// provider did not rotate/issue one — keep the previously stored value.
    let refreshToken: String?
}

// MARK: - Authenticator

/// Runs the full native OIDC sign-in flow for a server with
/// ``NativeSSOSettings`` configured:
///
/// 1. OIDC discovery at the issuer.
/// 2. Authorization Code + PKCE (S256) inside `ASWebAuthenticationSession`
///    (shared system-browser session → silent SSO + passkeys work).
/// 3. Code → access token at the IdP token endpoint (public client, no secret).
/// 4. Access token → Open WebUI session JWT at
///    `POST /api/v1/auths/oauth/{provider}/token/exchange`
///    (falls back to `/api/v1/oauth/{provider}/token/exchange` on 404/405 for
///    other server builds).
@MainActor
final class NativeOIDCAuthenticator: NSObject {
    /// Callback registered in Info.plist `CFBundleURLTypes` and at the IdP.
    static let redirectScheme = "openui"
    static let redirectURI = "openui://oauth-callback"

    /// `offline_access` makes the IdP return a refresh token for this public
    /// client (Keycloak only issues refresh tokens to public clients when
    /// this scope is requested) — required for silent session refresh.
    static let scopes = "openid email profile offline_access"

    private var webSession: ASWebAuthenticationSession?
    private let presentationProvider = WebAuthPresentationAnchorProvider()
    private let logger = Logger(subsystem: "com.openui", category: "NativeSSO")

    /// Performs the full flow and returns an Open WebUI session JWT plus the
    /// IdP refresh token, ready for ``AuthViewModel/loginWithSSOToken(_:)``
    /// and Keychain persistence respectively.
    func signIn(server: ServerConfig, providerKey: String) async throws -> NativeSSOSession {
        guard let settings = server.nativeSSO, settings.isConfigured else {
            throw NativeOIDCAuthError.notConfigured
        }

        // 1. Discovery
        let metadata = try await Self.discover(issuer: settings.issuerURL, allowSelfSigned: server.allowSelfSignedCertificates)

        // 2. Authorize via system browser
        let verifier = Self.makeCodeVerifier()
        let challenge = Self.makeCodeChallenge(from: verifier)
        let state = Self.makeRandomString(bytes: 32)
        let startURL = try authorizeURL(
            authorizationEndpoint: metadata.authorization_endpoint,
            clientID: settings.clientID,
            scopes: Self.scopes,
            state: state,
            codeChallenge: challenge
        )
        let callbackURL = try await present(startURL: startURL)
        let code = try parseCallback(callbackURL, expectedState: state)

        // 3. Code → access + refresh tokens (public client — no secret)
        let tokens = try await performTokenRequest(
            tokenEndpoint: metadata.token_endpoint,
            formItems: [
                URLQueryItem(name: "grant_type", value: "authorization_code"),
                URLQueryItem(name: "code", value: code),
                URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
                URLQueryItem(name: "client_id", value: settings.clientID),
                URLQueryItem(name: "code_verifier", value: verifier),
            ],
            allowSelfSigned: server.allowSelfSignedCertificates
        )

        // 4. Access token → Open WebUI session JWT
        let jwt = try await exchangeForOpenWebUIToken(
            server: server,
            providerKey: providerKey,
            accessToken: tokens.accessToken
        )
        logger.info("Native SSO: token exchange completed successfully (refresh token \(tokens.refreshToken != nil ? "issued" : "absent"))")
        return NativeSSOSession(jwt: jwt, refreshToken: tokens.refreshToken)
    }

    /// Silent refresh — **no browser UI**.
    ///
    /// Exchanges the stored IdP refresh token for a fresh access token
    /// (`grant_type=refresh_token`) and runs the Open WebUI token exchange
    /// again to mint a new session JWT. Call this when the Open WebUI JWT
    /// has expired (401) instead of interrupting the user with a re-login.
    ///
    /// If the IdP rotates refresh tokens, the new one is returned in
    /// ``NativeSSOSession/refreshToken``; otherwise the input value is
    /// echoed back so the caller can simply overwrite its storage.
    func refreshSession(server: ServerConfig, providerKey: String, refreshToken: String) async throws -> NativeSSOSession {
        guard let settings = server.nativeSSO, settings.isConfigured else {
            throw NativeOIDCAuthError.notConfigured
        }

        let metadata = try await Self.discover(issuer: settings.issuerURL, allowSelfSigned: server.allowSelfSignedCertificates)

        let tokens = try await performTokenRequest(
            tokenEndpoint: metadata.token_endpoint,
            formItems: [
                URLQueryItem(name: "grant_type", value: "refresh_token"),
                URLQueryItem(name: "refresh_token", value: refreshToken),
                URLQueryItem(name: "client_id", value: settings.clientID),
                URLQueryItem(name: "scope", value: Self.scopes),
            ],
            allowSelfSigned: server.allowSelfSignedCertificates
        )

        let jwt = try await exchangeForOpenWebUIToken(
            server: server,
            providerKey: providerKey,
            accessToken: tokens.accessToken
        )
        logger.info("Native SSO: silent session refresh completed")
        return NativeSSOSession(jwt: jwt, refreshToken: tokens.refreshToken ?? refreshToken)
    }

    // MARK: - Discovery

    private struct OIDCMetadata: Decodable {
        let authorization_endpoint: String
        let token_endpoint: String
        let issuer: String?
    }

    private static func discover(issuer: String, allowSelfSigned: Bool) async throws -> OIDCMetadata {
        let trimmed = issuer.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: trimmed), components.host != nil else {
            throw NativeOIDCAuthError.invalidIssuer
        }
        components.path = components.path.hasSuffix("/.well-known/openid-configuration")
            ? components.path
            : components.path + "/.well-known/openid-configuration"
        guard let url = components.url else { throw NativeOIDCAuthError.invalidIssuer }

        let (data, response) = try await makeSession(allowSelfSigned: allowSelfSigned, hosts: [url.host ?? ""])
            .data(from: url)
        guard let http = response as? HTTPURLResponse else { throw NativeOIDCAuthError.discoveryFailed(statusCode: -1) }
        guard http.statusCode == 200 else { throw NativeOIDCAuthError.discoveryFailed(statusCode: http.statusCode) }

        do {
            let metadata = try JSONDecoder().decode(OIDCMetadata.self, from: data)
            guard !metadata.authorization_endpoint.isEmpty, !metadata.token_endpoint.isEmpty else {
                throw NativeOIDCAuthError.missingEndpoints
            }
            return metadata
        } catch let error as NativeOIDCAuthError {
            throw error
        } catch {
            throw NativeOIDCAuthError.missingEndpoints
        }
    }

    // MARK: - Issuer detection

    /// Detect the IdP issuer **without any browser UI** by following Open
    /// WebUI's own OAuth login hand-off: `GET /oauth/{provider}/login`
    /// redirects to the IdP's authorize endpoint — the same redirect the
    /// embedded web view follows during regular SSO login. From that landing
    /// URL the issuer is recovered by probing
    /// `.well-known/openid-configuration` on successively shorter path
    /// prefixes (deepest first), e.g. Keycloak's
    /// `/realms/my/protocol/openid-connect/auth` or
    /// `/realms/my/login-actions/authenticate` resolve to `/realms/my`,
    /// and taking the authoritative `issuer` field from the metadata.
    ///
    /// Returns nil when the server does not redirect off-origin (provider not
    /// configured / auth required) or the IdP exposes no OIDC discovery.
    static func detectIssuerURL(server: ServerConfig, providerKey: String) async -> String? {
        let base = server.url.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedProvider = providerKey.trimmingCharacters(in: .whitespaces).lowercased()
        let provider = trimmedProvider.isEmpty ? "oidc" : trimmedProvider
        // Open WebUI serves the browser-facing OAuth routes at the root;
        // some versions mount them under the API prefix instead.
        let loginPaths = ["/oauth/\(provider)/login", "/api/v1/oauth/\(provider)/login"]

        var landing: URL?
        for path in loginPaths {
            guard let url = URL(string: base + path), let host = url.host else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("text/html", forHTTPHeaderField: "Accept")
            guard let (_, response) = try? await makeSession(allowSelfSigned: server.allowSelfSignedCertificates, hosts: [host])
                .data(for: request),
                let http = response as? HTTPURLResponse,
                let finalURL = http.url,
                // Only a real bounce off the Open WebUI origin counts as the
                // IdP hand-off; a same-origin 200/401 means no redirect.
                finalURL.host?.lowercased() != host.lowercased()
            else { continue }
            landing = finalURL
            break
        }
        guard let landing else { return nil }
        return await probeDiscovery(from: landing, allowSelfSigned: server.allowSelfSignedCertificates)
    }

    /// Probes `{scheme}://{host}{path-prefix}/.well-known/openid-configuration`
    /// for successively shorter prefixes of `url.path` (deepest first, down to
    /// the origin) and returns the first document's `issuer` — falling back to
    /// the probed prefix when the document omits `issuer`.
    private static func probeDiscovery(from url: URL, allowSelfSigned: Bool) async -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        let segments = url.path.split(separator: "/")
        let maxDepth = min(segments.count, 5)
        for depth in stride(from: maxDepth, through: 0, by: -1) {
            let prefix = segments.prefix(depth).map { "/\(String($0))" }.joined()
            let candidate = "\(scheme)://\(host)\(port)\(prefix)"
            if let metadata = try? await discover(issuer: candidate, allowSelfSigned: allowSelfSigned) {
                if let declared = metadata.issuer?.trimmingCharacters(in: .whitespacesAndNewlines), !declared.isEmpty {
                    return declared
                }
                return candidate
            }
        }
        return nil
    }

    // MARK: - Authorize

    private func authorizeURL(authorizationEndpoint: String, clientID: String, scopes: String,
                              state: String, codeChallenge: String) throws -> URL {
        guard var components = URLComponents(string: authorizationEndpoint) else {
            throw NativeOIDCAuthError.missingEndpoints
        }
        let items: [URLQueryItem] = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        var query = components.queryItems ?? []
        query.append(contentsOf: items)
        components.queryItems = query
        guard let url = components.url else { throw NativeOIDCAuthError.missingEndpoints }
        return url
    }

    /// One-shot guard so the presentation continuation resumes exactly once
    /// (the completion handler and a failed `start()` could both fire).
    private var presentationResumed = false

    private func present(startURL: URL) async throws -> URL {
        presentationResumed = false
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            // The completion-handler initializer is the designated initializer
            // across all SDK versions (the SDK 27 beta no longer exposes the
            // two-argument init at all).
            let session = ASWebAuthenticationSession(
                url: startURL,
                callbackURLScheme: Self.redirectScheme
            ) { [weak self] url, error in
                Task { @MainActor [weak self] in
                    guard let self, !self.presentationResumed else { return }
                    self.presentationResumed = true
                    self.webSession = nil
                    self.resumePresentation(continuation: continuation, url: url, error: error)
                }
            }
            session.presentationContextProvider = presentationProvider
            // Shared (non-ephemeral) browser session: users already signed in
            // at the IdP in Safari get silent SSO, and saved passkeys are offered.
            session.prefersEphemeralWebBrowserSession = false

            // Strongly retain the session for the duration of the flow.
            self.webSession = session

            // iOS 17.4+: sessions built with a completion-handler initializer
            // are only presented once `start()` is called explicitly.
            if !session.start() {
                logger.error("Native SSO: failed to start ASWebAuthenticationSession")
                Task { @MainActor [weak self] in
                    guard let self, !self.presentationResumed else { return }
                    self.presentationResumed = true
                    self.webSession = nil
                    continuation.resume(throwing: NativeOIDCAuthError.cancelled)
                }
            }
        }
    }

    private func resumePresentation(continuation: CheckedContinuation<URL, Error>, url: URL?, error: Error?) {
        if let error {
            let nsError = error as NSError
            if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
               nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                continuation.resume(throwing: NativeOIDCAuthError.cancelled)
            } else {
                continuation.resume(throwing: error)
            }
            return
        }
        if let url {
            continuation.resume(returning: url)
        } else {
            continuation.resume(throwing: NativeOIDCAuthError.cancelled)
        }
    }

    private func parseCallback(_ url: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw NativeOIDCAuthError.missingAuthorizationCode
        }
        let items = components.queryItems ?? []

        if let error = items.first(where: { $0.name == "error" })?.value {
            let description = items.first(where: { $0.name == "error_description" })?.value ?? error
            throw NativeOIDCAuthError.providerError(description: description)
        }
        if let state = items.first(where: { $0.name == "state" })?.value, state != expectedState {
            throw NativeOIDCAuthError.stateMismatch
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw NativeOIDCAuthError.missingAuthorizationCode
        }
        return code
    }

    // MARK: - Token

    fileprivate struct TokenResponse: Sendable {
        let accessToken: String
        let refreshToken: String?
    }

    /// POSTs a form-encoded grant to the IdP token endpoint and validates the
    /// response, shared by the authorization-code and refresh-token grants.
    private func performTokenRequest(tokenEndpoint: String, formItems: [URLQueryItem],
                                     allowSelfSigned: Bool) async throws -> TokenResponse {
        guard let url = URL(string: tokenEndpoint), let host = url.host else {
            throw NativeOIDCAuthError.missingEndpoints
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var form = URLComponents()
        form.queryItems = formItems
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        struct WireResponse: Decodable {
            let access_token: String?
            let refresh_token: String?
            let error: String?
            let error_description: String?
        }

        let (data, response) = try await Self.makeSession(allowSelfSigned: allowSelfSigned, hosts: [host]).data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NativeOIDCAuthError.tokenRequestFailed(statusCode: -1, detail: nil)
        }
        let decoded = try? JSONDecoder().decode(WireResponse.self, from: data)

        guard http.statusCode == 200, let accessToken = decoded?.access_token, !accessToken.isEmpty else {
            throw NativeOIDCAuthError.tokenRequestFailed(
                statusCode: http.statusCode,
                detail: decoded?.error_description ?? decoded?.error
            )
        }
        return TokenResponse(
            accessToken: accessToken,
            refreshToken: decoded?.refresh_token?.isEmpty == false ? decoded?.refresh_token : nil
        )
    }

    // MARK: - Open WebUI exchange

    /// FastAPI error bodies look like `{"detail": "..."}`. Success bodies use
    /// `token` per the exchange docs, but Open WebUI's session responses
    /// elsewhere use `access_token` — accept either.
    private struct ExchangeResponse: Decodable {
        let token: String?
        let accessToken: String?
        let detail: String?

        private enum CodingKeys: String, CodingKey {
            case token
            case accessToken = "access_token"
            case detail
        }

        var sessionToken: String? {
            if let token, !token.isEmpty { return token }
            if let accessToken, !accessToken.isEmpty { return accessToken }
            return nil
        }
    }

    private func exchangeForOpenWebUIToken(server: ServerConfig, providerKey: String, accessToken: String) async throws -> String {
        let provider = providerKey.lowercased()
        // Canonical path per the Open WebUI source (auths router). The
        // non-auths mount is kept as a fallback for other builds; both are
        // tried on 404/405.
        let paths = [
            "/api/v1/auths/oauth/\(provider)/token/exchange",
            "/api/v1/oauth/\(provider)/token/exchange",
        ]

        var lastError: NativeOIDCAuthError = .exchangeFailed(statusCode: -1, detail: nil)
        for path in paths {
            guard let url = URL(string: "\(server.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")))\(path)") else {
                throw NativeOIDCAuthError.exchangeFailed(statusCode: -1, detail: "Invalid server URL")
            }
            logger.debug("Native SSO: exchange attempt → POST \(url.absoluteString, privacy: .public)")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["token": accessToken])

            let (data, response) = try await Self.makeSession(
                allowSelfSigned: server.allowSelfSignedCertificates,
                hosts: [url.host ?? ""]
            ).data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw NativeOIDCAuthError.exchangeFailed(statusCode: -1, detail: nil)
            }
            let decoded = try? JSONDecoder().decode(ExchangeResponse.self, from: data)

            switch http.statusCode {
            case 200..<300:
                guard let jwt = decoded?.sessionToken, !jwt.isEmpty else {
                    throw NativeOIDCAuthError.exchangeFailed(statusCode: http.statusCode, detail: "Response contained no session token")
                }
                logger.info("Native SSO: exchange succeeded at \(path, privacy: .public)")
                return jwt
            case 404, 405:
                // 404: route not mounted here. 405: the path matched a *different*
                // route without a POST handler (common when the exchange lives
                // under the other router) — try the alternative mount point too.
                lastError = .exchangeFailed(statusCode: http.statusCode, detail: "Token exchange endpoint not found on the server (is ENABLE_OAUTH_TOKEN_EXCHANGE enabled?)")
                continue
            default:
                // Error bodies are FastAPI `{"detail": …}` — safe to log, and
                // the usual clue when the exchange route exists but rejects the
                // token (unknown client, introspection failure, …).
                let bodySnippet = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? "<non-utf8>"
                logger.warning("Native SSO: exchange failed at \(path, privacy: .public) with HTTP \(http.statusCode, privacy: .public): \(bodySnippet, privacy: .public)")
                throw NativeOIDCAuthError.exchangeFailed(
                    statusCode: http.statusCode,
                    detail: decoded?.detail
                )
            }
        }
        throw lastError
    }

    // MARK: - Session plumbing

    /// Ephemeral URLSession with no shared cookie storage — token-endpoint
    /// calls must never carry or receive the user's browser cookies.
    private static func makeSession(allowSelfSigned: Bool, hosts: [String]) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        let session: URLSession
        if allowSelfSigned {
            session = URLSession(configuration: config, delegate: SelfSignedTrustDelegate(allowedHosts: Set(hosts.map { $0.lowercased() })), delegateQueue: nil)
        } else {
            session = URLSession(configuration: config)
        }
        return session
    }

    // MARK: - PKCE / random helpers

    private static func makeCodeVerifier() -> String {
        makeRandomData(count: 32).base64URLEncodedString()
    }

    private static func makeCodeChallenge(from verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    private static func makeRandomString(bytes count: Int) -> String {
        makeRandomData(count: count).base64URLEncodedString()
    }

    private static func makeRandomData(count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }
}

// MARK: - Presentation anchor

/// Provides the key window for `ASWebAuthenticationSession` presentation.
final class WebAuthPresentationAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
        return active?.windows.first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

// MARK: - Self-signed certificate support

/// Trust delegate mirroring `APIClient`'s behaviour when the user has opted
/// into self-signed certificates for a server: accepts the server trust only
/// for the explicitly expected host.
private final class SelfSignedTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let allowedHosts: Set<String>

    init(allowedHosts: Set<String>) {
        self.allowedHosts = allowedHosts
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              allowedHosts.contains(challenge.protectionSpace.host.lowercased())
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}

// MARK: - Base64 URL helper

extension Data {
    /// RFC 7636 §5 base64url encoding (no padding).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
