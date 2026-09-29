import Foundation
import Security
import os.log

// MARK: - Client Certificate (mTLS)

/// A PKCS#12 client identity (certificate + private key) used for mutual TLS.
///
/// Servers placed behind an mTLS-enforcing reverse proxy (Nginx `ssl_verify_client`,
/// Traefik `RequireAndVerifyClientCert`, Caddy `client_auth`, Cloudflare Access mTLS…)
/// reject any connection that doesn't present a trusted client certificate.
/// iOS does not expose profile-installed identities to third-party apps, so the
/// user imports a `.p12` / `.pfx` file into the app instead.
nonisolated struct ClientCertificate: Sendable, Equatable {
    /// Raw PKCS#12 bytes as imported by the user.
    let pkcs12Data: Data
    /// Passphrase protecting the PKCS#12 bundle.
    let password: String
    /// Human-readable subject (usually the certificate's common name).
    let subject: String
    /// Certificate expiry date, when it could be read.
    let expiresAt: Date?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date()
    }

    /// Validates the PKCS#12 bundle and extracts its display metadata.
    /// Throws ``ClientCertificateError`` when the password is wrong or the
    /// file doesn't contain a usable identity.
    static func load(pkcs12Data: Data, password: String) throws -> ClientCertificate {
        let parsed = try Self.parse(pkcs12Data: pkcs12Data, password: password)
        var summary: String?
        var expiry: Date?
        var leaf: SecCertificate?
        if SecIdentityCopyCertificate(parsed.identity, &leaf) == errSecSuccess, let leaf {
            summary = SecCertificateCopySubjectSummary(leaf) as String?
            expiry = SecCertificateCopyNotValidAfterDate(leaf) as Date?
        }
        return ClientCertificate(
            pkcs12Data: pkcs12Data,
            password: password,
            subject: summary ?? String(localized: "Client Certificate"),
            expiresAt: expiry
        )
    }

    /// Builds the credential presented in response to a client-certificate challenge.
    func makeCredential() throws -> URLCredential {
        let parsed = try Self.parse(pkcs12Data: pkcs12Data, password: password)
        return URLCredential(
            identity: parsed.identity,
            certificates: parsed.intermediates.isEmpty ? nil : parsed.intermediates,
            persistence: .forSession
        )
    }

    private static func parse(
        pkcs12Data: Data,
        password: String
    ) throws -> (identity: SecIdentity, intermediates: [SecCertificate]) {
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password,
            kSecImportToMemoryOnly as String: true
        ]
        var rawItems: CFArray?
        let status = SecPKCS12Import(pkcs12Data as CFData, options as CFDictionary, &rawItems)
        switch status {
        case errSecSuccess:
            break
        case errSecAuthFailed, errSecPkcs12VerifyFailure:
            throw ClientCertificateError.wrongPassword
        default:
            throw ClientCertificateError.invalidFile(status: status)
        }

        guard let items = rawItems as? [[String: Any]],
              let first = items.first(where: { $0[kSecImportItemIdentity as String] != nil }),
              let identityRef = first[kSecImportItemIdentity as String],
              CFGetTypeID(identityRef as CFTypeRef) == SecIdentityGetTypeID()
        else {
            throw ClientCertificateError.noIdentity
        }
        let identity = identityRef as! SecIdentity // swiftlint:disable:this force_cast

        // The chain starts with the leaf; send only the intermediates so the
        // server can build the path to its trusted client CA.
        let chain = (first[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
        return (identity, Array(chain.dropFirst()))
    }
}

nonisolated enum ClientCertificateError: LocalizedError, Equatable {
    case wrongPassword
    case invalidFile(status: OSStatus)
    case noIdentity
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .wrongPassword:
            return String(localized: "Incorrect certificate password.")
        case .invalidFile:
            return String(localized: "This file isn't a valid .p12 or .pfx certificate.")
        case .noIdentity:
            return String(localized: "The certificate file doesn't contain a private key.")
        case .unreadableFile:
            return String(localized: "Couldn't read the selected file.")
        }
    }
}

// MARK: - Store

/// Persists client certificates in the Keychain, scoped to a server `host:port`.
///
/// Scoping by origin (instead of server ID) means every networking layer — URLSession
/// delegates, WebSockets, WKWebViews — can resolve the right identity from the
/// challenge's protection space alone, and the certificate is never presented to
/// any other host.
nonisolated final class ClientCertificateStore: @unchecked Sendable {
    static let shared = ClientCertificateStore()

    private let serviceName = "com.openui.client-certificate"
    private let logger = Logger(subsystem: "com.openui", category: "ClientCertificate")

    /// In-memory cache of resolved credentials (including negative lookups) so TLS
    /// handshakes don't hit the Keychain or re-parse the PKCS#12 bundle every time.
    private let lock = NSLock()
    private var credentialCache: [String: URLCredential?] = [:]

    private struct StoredItem: Codable {
        let pkcs12: Data
        let password: String
    }

    // MARK: Keys

    /// `host:port` key for a server URL string (e.g. `"chat.example.com:443"`).
    static func key(forServerURL serverURL: String) -> String? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme), let host = url.host, !host.isEmpty else { return nil }
        let scheme = url.scheme?.lowercased() ?? "https"
        let port = url.port ?? ((scheme == "http" || scheme == "ws") ? 80 : 443)
        return key(host: host, port: port)
    }

    static func key(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    // MARK: Read

    /// Full certificate (with display metadata) for a server, if one is stored.
    func certificate(forServerURL serverURL: String) -> ClientCertificate? {
        guard let key = Self.key(forServerURL: serverURL),
              let item = loadItem(key: key) else { return nil }
        return try? ClientCertificate.load(pkcs12Data: item.pkcs12, password: item.password)
    }

    /// Credential for an authentication challenge's protection space, if the user
    /// imported a certificate for exactly that origin.
    func credential(forHost host: String, port: Int) -> URLCredential? {
        credential(forKey: Self.key(host: host, port: port))
    }

    func credential(forServerURL serverURL: String) -> URLCredential? {
        guard let key = Self.key(forServerURL: serverURL) else { return nil }
        return credential(forKey: key)
    }

    private func credential(forKey key: String) -> URLCredential? {
        lock.lock()
        if let cached = credentialCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var credential: URLCredential?
        if let item = loadItem(key: key) {
            do {
                credential = try ClientCertificate(
                    pkcs12Data: item.pkcs12, password: item.password, subject: "", expiresAt: nil
                ).makeCredential()
            } catch {
                logger.error("Stored client certificate for \(key, privacy: .public) failed to load")
            }
        }

        lock.lock()
        credentialCache[key] = .some(credential)
        lock.unlock()
        return credential
    }

    // MARK: Write

    @discardableResult
    func save(_ certificate: ClientCertificate, forServerURL serverURL: String) -> Bool {
        guard let key = Self.key(forServerURL: serverURL),
              let data = try? JSONEncoder().encode(
                StoredItem(pkcs12: certificate.pkcs12Data, password: certificate.password)
              )
        else { return false }

        deleteItem(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        invalidateCache(key: key)
        if status == errSecSuccess {
            logger.info("Saved client certificate for \(key, privacy: .public)")
        } else {
            logger.error("Failed to save client certificate for \(key, privacy: .public): \(status)")
        }
        return status == errSecSuccess
    }

    func delete(forServerURL serverURL: String) {
        guard let key = Self.key(forServerURL: serverURL) else { return }
        deleteItem(key: key)
        invalidateCache(key: key)
    }

    /// Saves `certificate` for the server, or removes the stored one when `nil`.
    func set(_ certificate: ClientCertificate?, forServerURL serverURL: String) {
        if let certificate {
            save(certificate, forServerURL: serverURL)
        } else {
            delete(forServerURL: serverURL)
        }
    }

    // MARK: Keychain plumbing

    private func loadItem(key: String) -> StoredItem? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(StoredItem.self, from: data)
    }

    private func deleteItem(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func invalidateCache(key: String) {
        lock.lock()
        credentialCache.removeValue(forKey: key)
        lock.unlock()
    }
}

// MARK: - Shared Challenge Handling

/// Single source of truth for TLS authentication challenges across the app:
/// - **Client certificate (mTLS):** presents the imported identity for the challenge's
///   exact `host:port` (or the configured server, for IdP flows behind the same proxy).
/// - **Server trust:** accepts self-signed certificates only for the configured server
///   host, and only when the user opted in.
/// Everything else falls through to the system's default handling.
///
/// Also used by `WKNavigationDelegate`s — WebKit's challenge callback uses the
/// same disposition/credential types as URLSession.
nonisolated enum TLSChallengeHandler {
    static func resolve(
        _ challenge: URLAuthenticationChallenge,
        serverConfig: ServerConfig,
        checkPort: Bool = true
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        resolve(
            challenge,
            serverURL: serverConfig.url,
            allowSelfSigned: serverConfig.allowSelfSignedCertificates,
            checkPort: checkPort
        )
    }

    static func resolve(
        _ challenge: URLAuthenticationChallenge,
        serverURL: String?,
        allowSelfSigned: Bool,
        checkPort: Bool = true,
        clientCertificateFallbackServerURL: String? = nil
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace

        switch space.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            if let credential = clientCertificateCredential(
                for: challenge,
                fallbackServerURL: clientCertificateFallbackServerURL
            ) {
                return (.useCredential, credential)
            }
            return (.performDefaultHandling, nil)

        case NSURLAuthenticationMethodServerTrust:
            guard allowSelfSigned,
                  let serverTrust = space.serverTrust,
                  let serverURL,
                  let baseURL = URL(string: serverURL),
                  space.host.lowercased() == baseURL.host?.lowercased()
            else { return (.performDefaultHandling, nil) }
            if checkPort, let configPort = baseURL.port, space.port != configPort {
                return (.performDefaultHandling, nil)
            }
            return (.useCredential, URLCredential(trust: serverTrust))

        default:
            return (.performDefaultHandling, nil)
        }
    }

    /// Credential for a client-certificate challenge. Looks up the challenge's own
    /// origin first; `fallbackServerURL` lets scoped flows (native SSO talking to an
    /// identity provider behind the same mTLS proxy) reuse the server's identity.
    static func clientCertificateCredential(
        for challenge: URLAuthenticationChallenge,
        fallbackServerURL: String? = nil
    ) -> URLCredential? {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodClientCertificate else { return nil }
        if let credential = ClientCertificateStore.shared.credential(forHost: space.host, port: space.port) {
            return credential
        }
        if let fallbackServerURL {
            return ClientCertificateStore.shared.credential(forServerURL: fallbackServerURL)
        }
        return nil
    }

    /// Resolves a challenge for web views / one-off sessions that only know about
    /// client certificates (server trust stays with the system).
    static func resolveClientCertificateOnly(
        _ challenge: URLAuthenticationChallenge
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if let credential = clientCertificateCredential(for: challenge) {
            return (.useCredential, credential)
        }
        return (.performDefaultHandling, nil)
    }

    /// Whether a transport error means the server demanded (or rejected) a client certificate.
    static func isClientCertificateError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return urlError.code == .clientCertificateRequired || urlError.code == .clientCertificateRejected
    }

    /// Nginx answers `ssl_verify_client on` failures with an HTTP 400 page ("No required
    /// SSL certificate was sent") instead of failing the handshake. Detects that page
    /// (and the 495/496 codes some proxies use) so the user gets an actionable message.
    static func isClientCertificateRejectionPage(statusCode: Int, body: Data) -> Bool {
        if statusCode == 495 || statusCode == 496 { return true }
        guard statusCode == 400,
              let html = String(data: body.prefix(4096), encoding: .utf8)?.lowercased()
        else { return false }
        return html.contains("no required ssl certificate")
            || html.contains("ssl certificate error")
    }
}

// MARK: - Generic mTLS-aware Session

/// URLSession for one-off requests that may target the user's server (image previews,
/// file shares, model-switch status…). Presents a client certificate only to origins
/// that have one imported; server trust is always evaluated by the system.
nonisolated enum ClientCertificateSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        return URLSession(configuration: configuration, delegate: Delegate(), delegateQueue: nil)
    }()

    private final class Delegate: NSObject, URLSessionDelegate, Sendable {
        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            let (disposition, credential) = TLSChallengeHandler.resolveClientCertificateOnly(challenge)
            completionHandler(disposition, credential)
        }
    }
}
