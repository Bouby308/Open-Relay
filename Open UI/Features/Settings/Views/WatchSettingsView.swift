import SwiftUI
import WatchConnectivity

/// Settings → Apple Watch. The watch app is a remote for this iPhone:
/// it never signs in itself, so there's nothing account-related here.
struct WatchSettingsView: View {
    @Environment(\.theme) private var theme
    @AppStorage(WatchRelayService.enabledKey) private var enabled = true
    @AppStorage(WatchPhoneSpeaker.outputKey) private var replyOutput = "auto"
    @State private var watchStatus = WatchSettingsView.currentStatus()

    var body: some View {
        List {
            Section {
                LabeledContent("Status", value: watchStatus)
            } footer: {
                Text("Install Open Relay on your watch from the Watch app on this iPhone.")
            }

            Section {
                Toggle("Allow Apple Watch", isOn: $enabled)
                    .tint(theme.brandPrimary)
                    .onChange(of: enabled) { _, _ in
                        WatchRelayService.shared.refreshWatchIfNeeded()
                    }
            } footer: {
                Text("Your watch asks questions, reads chats and channels, and posts messages through this iPhone using the account you're signed in with. Your watch never stores your password or sign-in.")
            }

            Section {
                Picker("Play Spoken Replies On", selection: $replyOutput) {
                    Text("Automatic").tag("auto")
                    Text("iPhone").tag("phone")
                    Text("Apple Watch").tag("watch")
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("Voice")
            } footer: {
                Text("Automatic plays replies through headphones connected to this iPhone (like AirPods), so they keep playing when you lower your wrist. Otherwise replies play on the watch. Replies use the voice chosen in Settings → Voice.")
            }
        }
        .navigationTitle("Apple Watch")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { watchStatus = Self.currentStatus() }
    }

    static func currentStatus() -> String {
        guard WCSession.isSupported() else { return "Not supported" }
        let session = WCSession.default
        guard session.activationState == .activated else { return "Connecting…" }
        if !session.isPaired { return "No watch paired" }
        if !session.isWatchAppInstalled { return "App not installed on watch" }
        return session.isReachable ? "Connected" : "Installed"
    }

    static var subtitle: String {
        UserDefaults.standard.object(forKey: WatchRelayService.enabledKey) as? Bool ?? true
            ? currentStatus()
            : "Off"
    }
}
