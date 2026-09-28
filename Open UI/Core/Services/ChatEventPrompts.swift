import Foundation
import Observation

/// Transient, per-chat Socket.IO tool requests (`confirmation` / `input`) plus
/// server `notification` toasts. Only an explicit user response can approve a call.
@MainActor @Observable final class ChatEventPrompts {
    struct Request: Identifiable {
        let id = UUID()
        let isInput: Bool
        let payload: [String: Any]
        let reply: (Any?) -> Void

        var title: String { payload["title"] as? String ?? (isInput ? "Input Required" : "Confirm") }
        var message: String { payload["message"] as? String ?? payload["description"] as? String ?? "" }
        var value: String { payload["value"] as? String ?? "" }
        var placeholder: String { payload["placeholder"] as? String ?? "Your response" }
        var inputType: String {
            (payload["input"] as? [String: Any])?["type"] as? String ?? payload["type"] as? String ?? ""
        }
        var options: [(label: String, value: String)] {
            let values = (payload["input"] as? [String: Any])?["options"] ?? payload["options"]
            return (values as? [Any] ?? []).compactMap {
                if let value = $0 as? String { return (value, value) }
                guard let option = $0 as? [String: Any], let value = option["value"] as? String else { return nil }
                return (option["label"] as? String ?? value, value)
            }
        }
    }

    struct Notice: Identifiable {
        let id = UUID()
        let message: String
    }

    private(set) var requests: [Request] = []
    var notice: Notice?

    /// Routes a socket event. Requests that arrive while no stream is active (or that
    /// are malformed) are declined immediately so the server's `sio.call()` never hangs.
    func receive(type: String, payload: [String: Any]?, active: Bool, reply: ((Any?) -> Void)?) {
        if type == "notification" {
            if let message = payload?["content"] as? String ?? payload?["message"] as? String, !message.isEmpty {
                notice = Notice(message: message)
            }
            return
        }
        guard let reply else { return }
        guard active, let payload, type == "confirmation" || type == "input" else {
            reply(false)
            return
        }
        requests.append(Request(isInput: type == "input", payload: payload, reply: reply))
    }

    /// Answers the front request. Stale/duplicate taps are ignored.
    func respond(id: UUID, value: Any) {
        guard requests.first?.id == id else { return }
        // Remove before invoking the callback so double taps and reentrant replies are harmless.
        let request = requests.removeFirst()
        request.reply(value)
    }

    /// Declines every outstanding request (stream ended, chat closed, sheet dismissed).
    func cancelAll() {
        let pending = requests
        requests.removeAll()
        for request in pending { request.reply(false) }
    }
}
