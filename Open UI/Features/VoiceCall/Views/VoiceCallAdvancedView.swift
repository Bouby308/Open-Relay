import SwiftUI

/// Settings → Voice → Voice Calls → Advanced. Fine-grained turn-taking
/// controls. Every option is read when a call starts.
struct VoiceCallAdvancedView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @State private var confirmReset = false
    @State private var echoReset = false

    var body: some View {
        @Bindable var s = dependencies.voiceCallSettings
        List {
            Section {
                Toggle("Voice Detection", isOn: $s.vadEnabled)
                Toggle("Smart End-of-Turn", isOn: $s.smartTurnEnabled)
                    .disabled(!s.vadEnabled)
            } header: {
                Text("Detection")
            } footer: {
                Text(detectionFooter(s))
            }

            Section {
                Toggle("Custom Pause", isOn: $s.customPauseEnabled)
                if s.customPauseEnabled {
                    slider("Shortest pause", value: $s.customMinPause, range: VoiceCallSettings.minPauseRange, step: 0.1)
                    slider("Longest pause", value: $s.customMaxPause, range: VoiceCallSettings.maxPauseRange, step: 0.5)
                }
            } header: {
                Text("Pause Before Replying")
            } footer: {
                Text(s.customPauseEnabled
                     ? "The assistant replies after the shortest pause when you've clearly finished, and always replies after the longest pause. Without Smart End-of-Turn it waits \(String(format: "%.1f", s.pauseRange.min + (s.pauseRange.max - s.pauseRange.min) * 0.4)) s."
                     : "Uses the \(s.turnPace.displayName.replacingOccurrences(of: " (default)", with: "")) preset (\(String(format: "%.1f–%.1f", s.turnPace.minPause, s.turnPace.maxPause)) s). Turn on to set exact times.")
            }

            Section {
                Toggle("Custom Interrupt Time", isOn: Binding(
                    get: { s.interruptAfter != nil },
                    set: { s.interruptAfter = $0 ? 1.2 : nil }
                ))
                if let value = s.interruptAfter {
                    slider("Talk over for", value: Binding(get: { value }, set: { s.interruptAfter = $0 }),
                           range: VoiceCallSettings.sustainRange, step: 0.1)
                }
                Picker("Echo Protection", selection: $s.echoProtection) {
                    ForEach(EchoProtection.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Button("Reset Learned Echo") {
                    s.resetLearnedEcho()
                    echoReset = true
                    Haptics.play(.light)
                }
            } header: {
                Text("Interrupting")
            } footer: {
                Text("Interrupt time is how long you need to keep talking over the assistant before it stops. Background noise, taps and coughs never interrupt. Strong echo protection helps when the assistant cuts itself off on a loud speaker. The call learns your speaker's echo automatically; reset it after changing rooms or speakers if interruptions misbehave.")
            }
            .disabled(!s.vadEnabled || !s.bargeInEnabled)

            Section {
                Toggle("Show Diagnostics", isOn: $s.diagnosticsEnabled)
            } footer: {
                Text("Shows a live readout on the call screen: whether your voice is detected, the current pause, Smart Turn's confidence, echo level and why each decision was made.")
            }

            Section {
                Button("Reset to Defaults", role: .destructive) { confirmReset = true }
                    .disabled(!s.hasAdvancedChanges)
            } footer: {
                Text("Changes apply from the next call.")
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Reset advanced voice call settings?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { s.resetAdvanced() }
        }
        .alert("Learned echo cleared", isPresented: $echoReset) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The next call will re-learn your speaker's echo.")
        }
    }

    private func detectionFooter(_ s: VoiceCallSettings) -> String {
        if !s.vadEnabled {
            return "Off: your turn ends after a set silence based on microphone level, and interrupting by speaking is unavailable. Useful if voice detection misbehaves on your device."
        }
        if !s.smartTurnEnabled {
            return "Smart End-of-Turn is off: only the length of your pause decides when you've finished."
        }
        return "Voice Detection recognises speech (not noise). Smart End-of-Turn listens to how you speak to tell a thinking pause from a finished sentence."
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.1f s", value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }
}
