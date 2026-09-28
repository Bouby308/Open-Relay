import SwiftUI

/// Model for new chats + spoken replies. Account settings live on the iPhone.
struct WatchSettingsView: View {
    @Environment(WatchStore.self) private var store
    @Environment(WatchLink.self) private var link
    @State private var echoAllowed = WatchAudio.shared.echoAllowed

    var body: some View {
        @Bindable var store = store
        List {
            Section {
                Picker("Model", selection: $store.selectedModelId) {
                    Text("Server default").tag(String?.none)
                    ForEach(store.snapshot.models) { model in
                        Text(model.name).tag(Optional(model.id))
                    }
                }
            } footer: {
                Text("Used for new chats started on your watch.")
            }

            Section {
                Picker("Voice", selection: $store.voice) {
                    Text("Apple").tag("apple")
                    Text("Server").tag("server")
                }
                Toggle("Talk to Interrupt", isOn: $store.interruptBySpeaking)
                Toggle("Speak Typed Replies", isOn: $store.speakReplies)
                LabeledContent("Echo Cancellation", value: echoAllowed ? "On" : "Off (mic was silent)")
                if !echoAllowed {
                    Button("Try Echo Cancellation Again", systemImage: "arrow.clockwise") {
                        WatchAudio.shared.retryEcho()
                        echoAllowed = true
                    }
                }
            } header: {
                Text("Voice")
            } footer: {
                Text("Apple works offline and starts fastest. Server uses your server's voice, made on your iPhone — if a sentence isn't ready, Apple's voice fills in. With Talk to Interrupt, speaking over a reply stops it and listens. Replies play through headphones connected to your iPhone when there are some.")
            }

            Section("iPhone") {
                LabeledContent("Status", value: link.isReachable ? "Connected" : "Not connected")
                if let server = store.snapshot.serverName {
                    LabeledContent("Server", value: server)
                }
                if let user = store.snapshot.userName {
                    LabeledContent("Account", value: user)
                }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                    .disabled(store.isRefreshing)
            }
        }
        .navigationTitle("Settings")
    }
}
