import SwiftUI
import UniformTypeIdentifiers

// MARK: - Import Flow

/// Shared `.p12` / `.pfx` import flow: file picker → password prompt → validation.
/// Produces a validated ``ClientCertificate`` or shows an error alert.
private struct ClientCertificateImporter: ViewModifier {
    @Binding var isPresented: Bool
    let onImport: (ClientCertificate) -> Void

    @State private var pendingData: Data?
    @State private var password = ""
    @State private var showPasswordPrompt = false
    @State private var errorMessage: String?

    private static let allowedTypes: [UTType] = {
        var types: [UTType] = [.pkcs12]
        if let pfx = UTType(filenameExtension: "pfx"), !types.contains(pfx) { types.append(pfx) }
        types.append(.data) // some providers export .p12 with a generic type
        return types
    }()

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $isPresented,
                allowedContentTypes: Self.allowedTypes,
                allowsMultipleSelection: false
            ) { result in
                handlePick(result)
            }
            .alert("Certificate Password", isPresented: $showPasswordPrompt) {
                SecureField("Password", text: $password)
                Button("Cancel", role: .cancel) { reset() }
                Button("Import") { validate() }
            } message: {
                Text("Enter the password used to protect this certificate file.")
            }
            .alert(
                "Couldn't Import Certificate",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private func handlePick(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            errorMessage = ClientCertificateError.unreadableFile.localizedDescription
            return
        }
        pendingData = data
        password = ""
        // Let the file picker finish dismissing before presenting the alert.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            showPasswordPrompt = true
        }
    }

    private func validate() {
        guard let data = pendingData else { return }
        do {
            let certificate = try ClientCertificate.load(pkcs12Data: data, password: password)
            onImport(certificate)
            reset()
        } catch {
            reset()
            errorMessage = error.localizedDescription
        }
    }

    private func reset() {
        pendingData = nil
        password = ""
    }
}

extension View {
    func clientCertificateImporter(
        isPresented: Binding<Bool>,
        onImport: @escaping (ClientCertificate) -> Void
    ) -> some View {
        modifier(ClientCertificateImporter(isPresented: isPresented, onImport: onImport))
    }
}

// MARK: - Display Helpers

extension ClientCertificate {
    /// e.g. "Expires Mar 4, 2027" / "Expired Jan 2, 2025".
    var expiryDescription: String? {
        guard let expiresAt else { return nil }
        let date = expiresAt.formatted(date: .abbreviated, time: .omitted)
        return isExpired
            ? String(localized: "Expired \(date)")
            : String(localized: "Expires \(date)")
    }
}

enum ClientCertificateHelp {
    static let footer = """
    For servers behind a reverse proxy that requires mutual TLS (mTLS). Import a .p12 or .pfx file \
    containing your client certificate and private key. It's stored securely in the Keychain and only \
    sent to this server.
    """
}

// MARK: - Advanced Fields (connect screens)

/// "Client Certificate (mTLS)" row for the Advanced sections of the connect screens.
/// Styled to match the Self-Signed Certificates row above it.
struct ClientCertificateAdvancedField: View {
    @Binding var certificate: ClientCertificate?

    @Environment(\.theme) private var theme
    @State private var showImporter = false

    var body: some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Client Certificate (mTLS)")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)

                if let certificate {
                    Text(certificate.subject)
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                    if let expiry = certificate.expiryDescription {
                        Text(expiry)
                            .scaledFont(size: 11, weight: .medium)
                            .foregroundStyle(certificate.isExpired ? theme.error : theme.textTertiary)
                    }
                } else {
                    Text("For servers that require a .p12 / .pfx certificate")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }
            }

            Spacer()

            if certificate != nil {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { certificate = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 18)
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove client certificate")
            } else {
                Button("Import") { showImporter = true }
                    .scaledFont(size: 14, weight: .medium)
                    .tint(theme.brandPrimary)
            }
        }
        .clientCertificateImporter(isPresented: $showImporter) { imported in
            withAnimation(.easeInOut(duration: 0.2)) { certificate = imported }
        }
    }
}

// MARK: - Form Section (Settings → Edit Server)

/// `Form` variant of ``ClientCertificateAdvancedField`` for Settings → Edit Server.
struct ClientCertificateFormSection: View {
    @Binding var certificate: ClientCertificate?

    @State private var showImporter = false

    var body: some View {
        Section {
            if let certificate {
                LabeledContent("Certificate", value: certificate.subject)
                if let expiry = certificate.expiryDescription {
                    LabeledContent("Validity") {
                        Text(expiry)
                            .foregroundStyle(certificate.isExpired ? Color.red : Color.secondary)
                    }
                }
                Button("Replace Certificate") { showImporter = true }
                Button("Remove Certificate", role: .destructive) {
                    withAnimation { self.certificate = nil }
                }
            } else {
                Button("Import Certificate (.p12 / .pfx)") { showImporter = true }
            }
        } header: {
            Text("Client Certificate (mTLS)")
        } footer: {
            Text(ClientCertificateHelp.footer)
                .font(.caption)
        }
        .clientCertificateImporter(isPresented: $showImporter) { imported in
            withAnimation { certificate = imported }
        }
    }
}
