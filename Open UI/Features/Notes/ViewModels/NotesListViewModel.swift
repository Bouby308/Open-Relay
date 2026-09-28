import Foundation
import os.log

/// Manages the notes list state including search, grouping, and CRUD operations.
///
/// Updated to use server-backed ``NotesManager`` with async operations,
/// matching the Flutter `NotesList`, `NoteCreator`, `NoteDeleter` providers.
@MainActor @Observable
final class NotesListViewModel {

    // MARK: - State

    var notes: [Note] = []
    var searchText: String = ""
    var isLoading: Bool = false
    var errorMessage: String?
    /// Pin failures are shown in an alert, separate from the inline search error.
    var pinErrorMessage: String?
    /// Notes with a pin request in flight (duplicate toggles are disabled).
    private(set) var pinningNoteIDs: Set<String> = []

    /// Whether the notes feature is enabled on the server.
    var isFeatureEnabled: Bool = true

    /// The note being deleted (for confirmation dialog).
    var deletingNote: Note?

    // MARK: - Private

    private var manager: NotesManager?
    private let logger = Logger(subsystem: "com.openui", category: "NotesListVM")

    /// Accumulated server search results across loaded pages.
    private var searchResults: [Note] = []
    /// True while a search page request is in flight.
    var isSearching = false
    /// True when the server reports more matches than are loaded.
    var hasMoreSearchResults = false
    private var searchPage = 0
    /// Changes on every new query so stale/cancelled responses are ignored.
    private var searchGeneration = UUID()

    /// Task for debounced search.
    private var searchTask: Task<Void, Never>?

    // MARK: - Computed

    /// Notes filtered by search text (server results while searching).
    var filteredNotes: [Note] {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? notes : searchResults
    }

    /// Pinned notes.
    var pinnedNotes: [Note] {
        filteredNotes.filter(\.isPinned)
    }

    /// Notes grouped by time range.
    var groupedNotes: [(String, [Note])] {
        let unpinned = filteredNotes.filter { !$0.isPinned }
        var groups: [(String, [Note])] = []
        var today: [Note] = []
        var yesterday: [Note] = []
        var thisWeek: [Note] = []
        var thisMonth: [Note] = []
        var older: [Note] = []

        let calendar = Calendar.current
        let now = Date.now

        for note in unpinned {
            if calendar.isDateInToday(note.updatedAt) {
                today.append(note)
            } else if calendar.isDateInYesterday(note.updatedAt) {
                yesterday.append(note)
            } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
                      note.updatedAt > weekAgo {
                thisWeek.append(note)
            } else if let monthAgo = calendar.date(byAdding: .month, value: -1, to: now),
                      note.updatedAt > monthAgo {
                thisMonth.append(note)
            } else {
                older.append(note)
            }
        }

        if !today.isEmpty { groups.append(("Today", today)) }
        if !yesterday.isEmpty { groups.append(("Yesterday", yesterday)) }
        if !thisWeek.isEmpty { groups.append(("This Week", thisWeek)) }
        if !thisMonth.isEmpty { groups.append(("This Month", thisMonth)) }
        if !older.isEmpty { groups.append(("Older", older)) }

        return groups
    }

    // MARK: - Configuration

    func configure(with manager: NotesManager) {
        self.manager = manager
    }

    // MARK: - Operations

    /// Loads notes from the server (or local cache if unavailable).
    ///
    /// Matches the Flutter `NotesList.build()` which calls `api.getNotes()`
    /// and updates the `notesFeatureEnabledProvider`.
    func loadNotes() async {
        isLoading = true
        errorMessage = nil
        guard let manager else {
            isLoading = false
            return
        }
        notes = await manager.fetchNotes()
        isFeatureEnabled = manager.isServerEnabled
        isLoading = false
        if !searchText.isEmpty { triggerSearch() }
    }

    /// Refreshes the notes list from the server.
    func refreshNotes() async {
        guard let manager else { return }
        notes = await manager.fetchNotes()
        isFeatureEnabled = manager.isServerEnabled
        if !searchText.isEmpty { triggerSearch() }
    }

    /// Creates a new note on the server and returns it.
    ///
    /// Matches the Flutter `NoteCreator.createNote()` which posts to
    /// `/api/v1/notes/create`.
    @discardableResult
    func createNote() async -> Note? {
        guard let manager else { return nil }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let title = dateFormatter.string(from: .now)
        let note = await manager.createNote(title: title)
        await refreshNotes()
        return note
    }

    /// Deletes a note from the server.
    ///
    /// Matches the Flutter `NoteDeleter.deleteNote()`.
    func deleteNote(_ note: Note) async {
        guard let manager else { return }
        await manager.deleteNote(id: note.id)
        await refreshNotes()
    }

    /// Triggers a debounced server-side search. Call from onChange of searchText.
    func triggerSearch() {
        clearSearch()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let generation = searchGeneration
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, searchGeneration == generation else { return }
            await fetchSearchPage(query: query, page: 1, generation: generation)
        }
    }

    /// Resets search state and cancels any in-flight search.
    func clearSearch() {
        searchTask?.cancel()
        searchGeneration = UUID()
        searchResults = []
        searchPage = 0
        isSearching = false
        hasMoreSearchResults = false
        errorMessage = nil
    }

    /// Loads the next page of server search results.
    func loadMoreSearchResults() async {
        guard hasMoreSearchResults, !isSearching else { return }
        await retrySearch()
    }

    /// Retries (or continues) the search from the next unloaded page.
    func retrySearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isSearching else { return }
        isSearching = true
        await fetchSearchPage(query: query, page: searchPage + 1, generation: searchGeneration)
    }

    private func fetchSearchPage(query: String, page: Int, generation: UUID) async {
        guard let manager else { isSearching = false; return }
        errorMessage = nil
        defer { if searchGeneration == generation { isSearching = false } }
        do {
            let result = try await manager.searchNotes(query: query, page: page)
            guard !Task.isCancelled, searchGeneration == generation else { return }
            let existing = Set(searchResults.map(\.id))
            searchResults += result.notes.filter { !existing.contains($0.id) }
            searchPage = page
            hasMoreSearchResults = !result.notes.isEmpty && searchResults.count < result.total
        } catch {
            guard !Task.isCancelled, searchGeneration == generation else { return }
            logger.error("Notes search failed: \(error.localizedDescription)")
            errorMessage = "Couldn't search notes. Try again."
        }
    }

    /// Toggles a note's pin via the server (local-only notes toggle locally) and
    /// applies the confirmed state to the list and any loaded search results.
    /// Single attempt: a toggle is not idempotent, so failures are never retried.
    func togglePin(_ note: Note) async {
        guard let manager, pinningNoteIDs.insert(note.id).inserted else { return }
        defer { pinningNoteIDs.remove(note.id) }
        do {
            let pinned = try await manager.togglePin(note)
            if let index = notes.firstIndex(where: { $0.id == note.id }) { notes[index].isPinned = pinned }
            if let index = searchResults.firstIndex(where: { $0.id == note.id }) { searchResults[index].isPinned = pinned }
        } catch {
            logger.error("Note pin toggle failed: \(error.localizedDescription)")
            pinErrorMessage = "Could not update the pin. Refresh Notes before retrying. \(error.localizedDescription)"
        }
    }
}
