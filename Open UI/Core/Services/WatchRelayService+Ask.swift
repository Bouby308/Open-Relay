import Foundation

// MARK: - Prompt → reply turns

extension WatchRelayService {

    /// Longest reply text sent in one turn update (keeps messages small).
    static let replyLimit = 4_000

    func startAsk(_ req: WatchAskRequest) async throws -> WatchTurnState {
        if let existing = turns[req.turnId] { return existing.state }  // retried request
        let deps = try await ready()
        let text = req.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RelayError.bad("Nothing to send") }
        let record = TurnRecord(state: WatchTurnState(
            turnId: req.turnId, phase: .thinking, prompt: text, reply: "", sentences: [],
            sentenceStart: 0, chatId: req.chatId, chatTitle: nil, error: nil))
        turns[req.turnId] = record
        record.serverVoice = req.speak && req.serverVoice
        pruneTurns()
        beginWork()
        record.task = Task { [weak self] in
            await self?.run(record, text: text, chatId: req.chatId, modelId: req.modelId,
                            voice: req.voice, speak: req.speak, deps: deps)
            self?.endWork()
        }
        return record.state
    }

    /// Sends `text` to the chat and mirrors the streaming reply into `record`.
    func run(_ record: TurnRecord, text: String, chatId: String?, modelId: String?,
             voice: Bool, speak: Bool, deps: AppDependencyContainer) async {
        guard let manager = deps.conversationManager else {
            return fail(record, "Open Relay isn't ready on your iPhone.")
        }
        let chat = await chatViewModel(for: chatId, modelId: modelId, deps: deps, manager: manager)
        record.chat = chat
        guard !Task.isCancelled else { return }
        guard chat.selectedModelId != nil else { return fail(record, "No model is available on your server.") }

        let onPhone = speak && WatchPhoneSpeaker.shared.shouldSpeakOnPhone
        record.state.speaksOnPhone = onPhone
        if onPhone { WatchPhoneSpeaker.shared.begin(turnId: record.state.turnId) }

        let known = ResponseTextStream.assistantIds(in: chat)
        let previousVoiceMode = chat.isVoiceMode
        chat.isVoiceMode = voice
        chat.suppressCompletionNotification = true
        defer { chat.suppressCompletionNotification = false }
        var sendDone = false
        let sendTask = Task { @MainActor in
            await chat.sendMessage(directText: text)
            sendDone = true
        }
        var chunker = SentenceChunker()
        var speakable = ""
        var raw = ""
        for await full in ResponseTextStream.stream(for: chat, knownAssistantIds: known, sendFinished: { sendDone }) {
            if Task.isCancelled { break }
            raw = full
            speakable = SpeakableReplyFilter.filter(full)
            addSentences(chunker.feed(speakable), to: record, onPhone: onPhone)
            record.state.phase = .streaming
            record.state.reply = WatchTextFormatter.display(full, limit: Self.replyLimit)
        }
        if Task.isCancelled { sendTask.cancel() }
        _ = await sendTask.value
        chat.isVoiceMode = previousVoiceMode
        guard !Task.isCancelled else { return }

        addSentences(chunker.flush(speakable), to: record, onPhone: onPhone)
        if onPhone { WatchPhoneSpeaker.shared.finishInput(turnId: record.state.turnId) }
        record.state.reply = WatchTextFormatter.display(raw, limit: Self.replyLimit)
        let newId = chat.conversation?.id ?? chatId
        record.state.chatId = newId
        record.state.chatTitle = chat.conversation?.title
        if chatId == nil, let newId { watchChats[newId] = chat }
        if record.state.reply.isEmpty {
            let error = chat.errorMessage.flatMap { $0.isEmpty ? nil : $0 } ?? "No reply came back."
            fail(record, error)
        } else {
            record.state.phase = .done
            record.state.followUps = Self.followUps(in: chat)
            if record.state.followUps.isEmpty { watchFollowUps(record, chat: chat) }
        }
    }

    /// Follow-up suggestions on the newest assistant message (≤ 3, short).
    static func followUps(in chat: ChatViewModel) -> [String] {
        let latest = chat.messages.last(where: { $0.role == .assistant })?.followUps ?? []
        return latest.prefix(3).map { String($0.prefix(120)) }
    }

    /// The server sends follow-ups a moment after the reply ends — keep
    /// checking for a short while so the watch can show them.
    private func watchFollowUps(_ record: TurnRecord, chat: ChatViewModel) {
        Task { [weak record, weak chat] in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let record, let chat else { return }
                let found = Self.followUps(in: chat)
                if !found.isEmpty { record.state.followUps = found; return }
            }
        }
    }

    private func addSentences(_ sentences: [String], to record: TurnRecord, onPhone: Bool) {
        guard !sentences.isEmpty else { return }
        if onPhone {
            WatchPhoneSpeaker.shared.enqueue(sentences, turnId: record.state.turnId)
        } else {
            if record.serverVoice {
                Self.clipMaker.enqueue(sentences, turn: record.state.turnId, startIndex: record.sentences.count)
            }
            record.sentences.append(contentsOf: sentences)
        }
    }

    private func chatViewModel(for chatId: String?, modelId: String?, deps: AppDependencyContainer,
                               manager: ConversationManager) async -> ChatViewModel {
        let store = deps.activeChatStore
        let chat: ChatViewModel
        if let chatId {
            chat = watchChats[chatId] ?? store.viewModel(for: chatId)
        } else {
            // A standalone VM so the iPhone's own "new chat" screen is untouched.
            chat = ChatViewModel()
            if !store.cachedModels.isEmpty {
                chat.availableModels = store.cachedModels
                chat.selectedModelId = store.cachedDefaultModelId ?? store.cachedModels.first?.id
            }
        }
        if !chat.isConfigured {
            chat.configure(with: manager, socket: deps.socketService, store: store, notes: deps.notesManager)
        }
        await chat.load()
        if chatId == nil, let modelId, modelId != chat.selectedModelId,
           chat.availableModels.contains(where: { $0.id == modelId }) {
            chat.selectModel(modelId)
        }
        if chat.selectedModelId == nil { chat.selectedModelId = chat.availableModels.first?.id }
        return chat
    }
}
