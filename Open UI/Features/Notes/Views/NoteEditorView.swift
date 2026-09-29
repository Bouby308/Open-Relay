import SwiftUI
import UniformTypeIdentifiers

/// Editor view for a single note with markdown editing,
/// audio recording, and file attachment support.
struct NoteEditorView: View {
    let noteId: String

    @State private var note: Note?
    @State private var titleText: String = ""
    @State private var contentText: String = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var hasChanges = false
    @State private var showAudioRecorder = false
    @State private var showFilePicker = false
    @State private var files: NoteFilesModel?
    @State private var importTask: Task<Void, Never>?
    @State private var isImporting = false
    @State private var isPreviewMode = true
    @State private var recordingService = AudioRecordingService()
    @State private var isGeneratingTitle = false
    @State private var isEnhancing = false
    @State private var aiErrorMessage: String?
    @State private var autoSaveTask: Task<Void, Never>?
    @State private var sharingModel: NoteSharingModel?
    @State private var showSharing = false
    @State private var noteChatSession: NoteChatSession?
    @State private var noteChatDraft: ChatViewModel?
    @State private var linkedChat: Conversation?
    @State private var isOpeningChat = false
    @State private var draftSession: NoteDraftSession?
    @State private var draftLoadError: String?
    @State private var showDiscardDraft = false
    @State private var draftActionError: String?

    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @FocusState private var isContentFocused: Bool

    private var notesManager: NotesManager? {
        dependencies.notesManager
    }

    private var apiClient: APIClient? {
        dependencies.apiClient
    }

    private var canEdit: Bool { note?.canEdit == true }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading note…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let note {
                editorContent(note)
            } else {
                ContentUnavailableView(
                    "Note Not Found",
                    systemImage: "exclamationmark.triangle",
                    description: Text(draftLoadError ?? "This note could not be loaded.")
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await openChat() }
                } label: {
                    if isOpeningChat { ProgressView() }
                    else { Image(systemName: "bubble.left.and.bubble.right") }
                }
                .accessibilityLabel("Chat about note")
                .disabled(note == nil || isOpeningChat || isSaving || hasChanges)
            }
            if canEdit {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: Spacing.sm) {
                        // Note actions
                        Menu {
                            if let api = apiClient, let user = dependencies.authViewModel.currentUser {
                                Button("Manage Access", systemImage: "person.2") {
                                    let container = dependencies
                                    sharingModel = NoteSharingModel(noteId: noteId, api: api, user: user) { [weak container] in
                                        container?.apiClient === api && container?.authViewModel.currentUser?.id == user.id
                                    }
                                    showSharing = true
                                }
                                Divider()
                            }
                            Button {
                                Task { await generateTitle() }
                            } label: {
                                SwiftUI.Label(
                                    isGeneratingTitle ? "Generating..." : "Generate Title",
                                    systemImage: "sparkles"
                                )
                            }
                            .disabled(isGeneratingTitle || contentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            Button {
                                Task { await enhanceContent() }
                            } label: {
                                SwiftUI.Label(
                                    isEnhancing ? "Enhancing…" : "Enhance with AI",
                                    systemImage: "wand.and.stars"
                                )
                            }
                            .disabled(isEnhancing || contentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        } label: {
                            if isGeneratingTitle || isEnhancing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "ellipsis")
                            }
                        }
                        .accessibilityLabel("Note Actions")

                        // Preview toggle
                        Button {
                            isPreviewMode.toggle()
                        } label: {
                            Image(systemName: isPreviewMode ? "pencil" : "eye")
                        }
                        .accessibilityLabel(isPreviewMode ? "Edit" : "Preview")

                        // Audio recording
                        Button {
                            showAudioRecorder = true
                        } label: {
                            Image(systemName: "mic.circle")
                        }
                        .accessibilityLabel("Record audio")
                        .disabled(files?.canEdit != true || files?.isBusy == true || files?.pending != nil || isImporting)

                        // File attachment
                        Button {
                            showFilePicker = true
                        } label: {
                            Image(systemName: "paperclip")
                        }
                        .accessibilityLabel("Attach file")
                        .disabled(files?.canEdit != true || files?.isBusy == true || files?.pending != nil || isImporting)

                        // Save indicator
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else if hasChanges {
                            Circle()
                                .fill(theme.brandPrimary)
                                .frame(width: 8, height: 8)
                        }
                    }
                }
            }
        }
        .alert("Note Error", isPresented: .init(
            get: { aiErrorMessage != nil },
            set: { if !$0 { aiErrorMessage = nil } }
        )) {
            Button("OK") { aiErrorMessage = nil }
        } message: {
            Text(aiErrorMessage ?? "")
        }
        .task(id: dependencies.noteDraftStore?.identity) { await loadNote() }
        .confirmationDialog("Discard the local changes and reload the server version?", isPresented: $showDiscardDraft) {
            Button("Discard Local Changes", role: .destructive) {
                do {
                    try draftSession?.store.discard(noteId)
                    hasChanges = false
                    Task { await loadNote() }
                } catch { draftActionError = "Couldn’t discard the saved draft. A save may still be in progress. Please try again." }
            }
        }
        .alert("Saved Changes", isPresented: .init(get: { draftActionError != nil }, set: { if !$0 { draftActionError = nil } })) {
            Button("OK") { draftActionError = nil }
        } message: { Text(draftActionError ?? "") }
        .onChange(of: noteChatSession?.revision) { previous, _ in
            // A completed background chat may have edited the note. Never replace
            // text while the user is editing, or start the editor's autosave loop.
            if previous != nil && isPreviewMode && !hasChanges && !isSaving { Task { await reloadNote() } }
        }
        .sheet(item: $linkedChat, onDismiss: {
            if !hasChanges && !isSaving { Task { await reloadNote() } }
        }) { chat in
            if let noteChatSession {
                NoteChatsView(session: noteChatSession, initialChat: chat, draft: $noteChatDraft)
            }
        }
        .sheet(isPresented: $showSharing) {
            if let sharingModel { NoteSharingView(model: sharingModel) }
        }
        .sheet(isPresented: $showAudioRecorder) {
            AudioRecorderSheet(recordingService: recordingService) { result in
                handleAudioRecording(result)
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
        .onDisappear {
            importTask?.cancel()
            autoSaveTask?.cancel()
        }
    }

    // MARK: - Editor Content

    private func editorContent(_ note: Note) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    // Title
                    if isPreviewMode || !canEdit {
                        Text(titleText.isEmpty ? "Untitled" : titleText)
                            .scaledFont(size: 28, weight: .bold)
                            .foregroundStyle(theme.textPrimary)
                    } else {
                        TextField("Title", text: Binding(get: { titleText }, set: {
                            titleText = $0
                            scheduleAutoSave()
                        }))
                            .scaledFont(size: 28, weight: .bold)
                            .foregroundStyle(theme.textPrimary)
                    }

                    // Metadata
                    if !note.canEdit {
                        Label("Read Only", systemImage: "lock")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: Spacing.md) {
                        Text("\(contentText.split(whereSeparator: \.isWhitespace).count) words")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textTertiary)

                        Text("\(contentText.count) characters")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textTertiary)

                        Spacer()

                        Text("Updated \(note.updatedAt.chatTimestamp)")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                    }

                    Divider()
                        .foregroundStyle(theme.divider)

                    if let draftLoadError {
                        Text(draftLoadError).foregroundStyle(.red)
                    }
                    if hasChanges, let draftSession, draftSession.requiresRetry || draftSession.error != nil {
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            Text(draftSession.error?.rawValue ?? "Changes saved on this device. Not yet synced to the server.")
                                .font(.callout)
                            let layout = dynamicTypeSize.isAccessibilitySize
                                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.sm))
                                : AnyLayout(HStackLayout())
                            layout {
                                Button("Retry", systemImage: "arrow.clockwise") { Task { await saveNote() } }
                                    .disabled(isSaving)
                                ShareLink(item: "# \(titleText)\n\n\(contentText)") {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                Button("Discard", systemImage: "trash", role: .destructive) { showDiscardDraft = true }
                                    .disabled(isSaving)
                            }
                        }
                        .padding(Spacing.md)
                        .background(theme.surfaceContainer, in: RoundedRectangle(cornerRadius: CornerRadius.sm))
                    }

                    if let files {
                        NoteFilesSection(model: files)
                    }
                    if isImporting { ProgressView("Importing attachment…") }

                    // Content area — fills remaining screen height
                    if isPreviewMode || !canEdit {
                        markdownPreview
                    } else {
                        markdownEditor(screenHeight: geometry.size.height)
                    }
                }
                .padding(Spacing.screenPadding)
            }
        }
    }

    // MARK: - Markdown Editor

    private func markdownEditor(screenHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Formatting toolbar
            markdownToolbar

            TextEditor(text: Binding(get: { contentText }, set: {
                contentText = $0
                scheduleAutoSave()
            }))
                .scaledFont(size: 16)
                .foregroundStyle(theme.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: max(400, screenHeight * 0.6))
                .focused($isContentFocused)
        }
    }

    /// A row of markdown formatting buttons.
    private var markdownToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xs) {
                markdownButton("H1", action: { insertMarkdown("# ") })
                markdownButton("H2", action: { insertMarkdown("## ") })
                markdownButton("B", action: { wrapSelection("**") })
                markdownButton("I", action: { wrapSelection("*") })
                markdownButton("~", action: { wrapSelection("~~") })
                markdownButton("`", action: { wrapSelection("`") })
                markdownButton("•", action: { insertMarkdown("- ") })
                markdownButton("1.", action: { insertMarkdown("1. ") })
                markdownButton("[ ]", action: { insertMarkdown("- [ ] ") })
                markdownButton(">", action: { insertMarkdown("> ") })
                markdownButton("---", action: { insertMarkdown("\n---\n") })
                markdownButton("```", action: { insertMarkdown("```\n\n```") })
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    private func markdownButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .scaledFont(size: 14, design: .monospaced)
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(theme.surfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
        }
    }

    // MARK: - Markdown Preview

    private var markdownPreview: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if contentText.isEmpty {
                Text("Nothing to preview")
                    .scaledFont(size: 16)
                    .foregroundStyle(theme.textTertiary)
                    .italic()
            } else {
                StreamingMarkdownView(
                    content: contentText,
                    isStreaming: false,
                    textColor: theme.textPrimary
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Helpers

    private func loadNote() async {
        autoSaveTask?.cancel()
        isLoading = true
        isSaving = false
        hasChanges = false
        note = nil
        titleText = ""
        contentText = ""
        draftSession = nil
        draftLoadError = nil
        guard let manager = notesManager else {
            isLoading = false
            return
        }
        // Signed-in notes require an account-scoped recovery store before editing.
        let store = dependencies.noteDraftStore
        guard apiClient == nil || store != nil else {
            isLoading = false
            return
        }
        var recovered: NoteDraftStore.Entry?
        do {
            if let store, let apiClient {
                draftSession = try NoteDraftSession(noteID: noteId, api: apiClient, store: store,
                    isCurrent: { dependencies.apiClient === apiClient && dependencies.noteDraftStore?.identity == store.identity })
                recovered = try store.load(noteId)
            }
        } catch {
            draftLoadError = "Couldn’t read the saved draft. It has not been deleted."
            isLoading = false
            return
        }
        let session = draftSession
        var serverJSON: [String: Any]?
        if let api = apiClient {
            let container = dependencies
            let userId = container.authViewModel.currentUser?.id
            let model = NoteFilesModel(noteId: noteId, api: api) { [weak container] in
                container?.apiClient === api && container?.authViewModel.currentUser?.id == userId
            }
            files = model
            serverJSON = await model.load()
            guard !Task.isCancelled, model.sessionIsCurrent else { return }
        }
        guard draftSession === session, dependencies.noteDraftStore?.identity == store?.identity else { return }
        if let recovered {
            // A server refresh must never replace an unsynced recovery copy.
            note = recovered.original
            titleText = recovered.edited.title
            contentText = recovered.edited.content
            hasChanges = true
        } else {
            if let serverJSON { note = Note.fromServerJSON(serverJSON) }
            if note == nil { note = manager.fetchLocalNote(id: noteId) }
            if let note {
                titleText = note.title
                contentText = note.content
            }
        }
        isLoading = false
    }

    /// Refreshes the note after a linked chat may have edited it on the server.
    /// Skips the update if the user started editing while the request was in flight,
    /// or if an unsynced recovery copy exists.
    private func reloadNote() async {
        guard let manager = notesManager, draftSession?.requiresRetry != true else { return }
        let titleBeforeLoad = titleText
        let contentBeforeLoad = contentText
        let session = draftSession
        let serverNote = await manager.fetchNote(id: noteId)
        guard dependencies.notesManager === manager, draftSession === session, !hasChanges, !isSaving,
              titleText == titleBeforeLoad, contentText == contentBeforeLoad,
              let serverNote else { return }
        note = serverNote
        titleText = serverNote.title
        contentText = serverNote.content
        await files?.load()
    }

    private func scheduleAutoSave() {
        guard canEdit, !isLoading, let note, draftLoadError == nil else { return }
        guard hasChanges || titleText != note.title || contentText != note.content else { return }
        hasChanges = true
        autoSaveTask?.cancel()
        // Persist the edit on this device before any network write.
        if let draftSession, !draftSession.stage(original: note, title: titleText, content: contentText) { return }
        // Recovered or failed edits are only resubmitted by an explicit Retry.
        guard draftSession?.requiresRetry != true else { return }
        autoSaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            // Cancelling the debounce must not cancel a write already on the wire.
            Task {
                guard draftSession?.requiresRetry != true else { return }
                await saveNote()
            }
        }
    }

    private func saveNote() async {
        guard canEdit else { return }
        if let draftSession {
            guard !isSaving, draftLoadError == nil else { return }
            guard let baseline = note, draftSession.stage(original: baseline, title: titleText, content: contentText) else { return }
            isSaving = true
            let saved = await draftSession.save()
            guard self.draftSession === draftSession,
                  dependencies.noteDraftStore?.identity == draftSession.store.identity else { return }
            isSaving = false
            if let saved { note = saved }
            do { hasChanges = try draftSession.store.load(noteId) != nil }
            catch { draftLoadError = "Couldn’t read the saved draft. It has not been deleted." }
            if !hasChanges, let saved {
                titleText = saved.title
                contentText = saved.content
            }
            if saved != nil && hasChanges { scheduleAutoSave() }
            return
        }
        // Signed-in notes require an account-scoped recovery store before saving.
        guard apiClient == nil, var updatedNote = note else { return }
        isSaving = true

        updatedNote.title = titleText
        updatedNote.content = contentText
        // Only send content when the body was actually edited, so a rename keeps
        // the server's rich JSON/HTML content intact.
        let saved = await notesManager?.updateNote(updatedNote, contentChanged: contentText != note?.content) == true
        if saved { note = updatedNote }

        isSaving = false
        // Keep the note dirty after a failed save (or edits made mid-save) so it retries.
        hasChanges = !saved || titleText != updatedNote.title || contentText != updatedNote.content
    }

    // MARK: - AI Features

    private func openChat() async {
        guard let apiClient, !isOpeningChat, !hasChanges, !isSaving else { return }
        isOpeningChat = true
        defer { isOpeningChat = false }
        let session = noteChatSession ?? NoteChatSession(noteId: noteId, api: apiClient,
                                                        isCurrent: { dependencies.apiClient === apiClient })
        do {
            let chat = try await session.open(title: titleText, content: contentText)
            isPreviewMode = true
            isContentFocused = false
            noteChatSession = session
            linkedChat = chat
        } catch is CancellationError {
        } catch {
            aiErrorMessage = error.localizedDescription
        }
    }

    /// Generates a title for the note using AI.
    private func generateTitle() async {
        guard canEdit, let apiClient,
              !contentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        isGeneratingTitle = true
        aiErrorMessage = nil

        do {
            let defaultModel = await apiClient.getDefaultModel()
            guard let modelId = defaultModel else {
                aiErrorMessage = "No AI model available. Please configure a model first."
                isGeneratingTitle = false
                return
            }

            if let title = try await apiClient.generateNoteTitle(
                content: contentText, modelId: modelId
            ) {
                titleText = title
                hasChanges = true
                scheduleAutoSave()
            }
        } catch {
            aiErrorMessage = "Failed to generate title: \(error.localizedDescription)"
        }

        isGeneratingTitle = false
    }

    /// Enhances the note content using AI.
    private func enhanceContent() async {
        guard canEdit, let apiClient,
              !contentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        isEnhancing = true
        aiErrorMessage = nil

        do {
            let defaultModel = await apiClient.getDefaultModel()
            guard let modelId = defaultModel else {
                aiErrorMessage = "No AI model available. Please configure a model first."
                isEnhancing = false
                return
            }

            if let enhanced = try await apiClient.enhanceNoteContent(
                content: contentText, modelId: modelId
            ) {
                contentText = enhanced
                hasChanges = true
                scheduleAutoSave()
            }
        } catch {
            aiErrorMessage = "Failed to enhance content: \(error.localizedDescription)"
        }

        isEnhancing = false
    }

    private func handleAudioRecording(_ result: RecordingResult) {
        guard canEdit, let files else { return }
        importTask = Task { await files.attach(data: result.data, name: result.fileName) }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard canEdit, let files else { return }
        guard case .success(let urls) = result else {
            if case .failure(let error) = result { files.error = error.localizedDescription }
            return
        }
        guard !isImporting else { return }
        isImporting = true
        importTask = Task {
            defer { isImporting = false }
            for url in urls {
                do {
                    try Task.checkCancellation()
                    let data = try await Task.detached(priority: .userInitiated) {
                        let accessed = url.startAccessingSecurityScopedResource()
                        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                        return try Data(contentsOf: url, options: .mappedIfSafe)
                    }.value
                    try Task.checkCancellation()
                    await files.attach(data: data, name: url.lastPathComponent)
                    if files.error != nil { break }
                } catch {
                    if !Task.isCancelled { files.error = error.localizedDescription }
                    break
                }
            }
        }
    }

    private func insertMarkdown(_ prefix: String) {
        contentText += prefix
        scheduleAutoSave()
    }

    private func wrapSelection(_ wrapper: String) {
        contentText += "\(wrapper)text\(wrapper)"
        scheduleAutoSave()
    }
}

// MARK: - Audio Recorder Sheet

struct AudioRecorderSheet: View {
    @Bindable var recordingService: AudioRecordingService
    let onComplete: (RecordingResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.xl) {
                Spacer()

                // Waveform visualization
                HStack(spacing: 4) {
                    ForEach(0..<20, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(theme.brandPrimary)
                            .frame(width: 4, height: barHeight(for: index))
                    }
                }
                .frame(height: 80)

                // Duration
                Text(formatDuration(recordingService.duration))
                    .scaledFont(size: 36, weight: .bold)
                    .foregroundStyle(theme.textPrimary)
                    .monospacedDigit()

                Spacer()

                // Controls
                HStack(spacing: Spacing.xxl) {
                    // Cancel
                    Button {
                        recordingService.cancelRecording()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .scaledFont(size: 48)
                            .foregroundStyle(theme.textTertiary)
                    }

                    // Record / Pause
                    Button {
                        switch recordingService.state {
                        case .idle:
                            Task { try? await recordingService.startRecording() }
                        case .recording:
                            recordingService.pauseRecording()
                        case .paused:
                            recordingService.resumeRecording()
                        default:
                            break
                        }
                    } label: {
                        Circle()
                            .fill(theme.error)
                            .frame(width: 72, height: 72)
                            .overlay(
                                Group {
                                    if case .recording = recordingService.state {
                                        Image(systemName: "pause.fill")
                                            .scaledFont(size: 32)
                                            .foregroundStyle(.white)
                                    } else {
                                        Circle()
                                            .fill(.white)
                                            .frame(width: 24, height: 24)
                                    }
                                }
                            )
                    }

                    // Done
                    Button {
                        if let result = recordingService.stopRecording() {
                            onComplete(result)
                        }
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .scaledFont(size: 48)
                            .foregroundStyle(theme.success)
                    }
                    .disabled(recordingService.state == .idle)
                }

                Spacer().frame(height: Spacing.xxl)
            }
            .navigationTitle("Record Audio")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }

    private func barHeight(for index: Int) -> CGFloat {
        let level = CGFloat(recordingService.audioLevel)
        let variation = sin(CGFloat(index) * 0.5) * 0.3
        return max(4, (level + variation) * 60)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
