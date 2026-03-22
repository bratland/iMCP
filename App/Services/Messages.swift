import AppKit
import OSLog
import SQLite3
import UniformTypeIdentifiers
import iMessage

private let log = Logger.service("messages")
private let messagesDatabasePath = "/Users/\(NSUserName())/Library/Messages/chat.db"
private let messagesDatabaseBookmarkKey: String = "me.mattt.iMCP.messagesDatabaseBookmark"
private let defaultLimit = 30

final class MessageService: NSObject, Service, NSOpenSavePanelDelegate {
    static let shared = MessageService()

    func activate() async throws {
        log.debug("Starting message service activation")

        if canAccessDatabaseAtDefaultPath {
            log.debug("Successfully activated using default database path")
            return
        }

        if canAccessDatabaseUsingBookmark {
            log.debug("Successfully activated using stored bookmark")
            return
        }

        log.debug("Opening file picker for manual database selection")
        guard try await showDatabaseAccessAlert() else {
            throw DatabaseAccessError.userDeclinedAccess
        }

        let selectedURL = try await showFilePicker()

        guard FileManager.default.isReadableFile(atPath: selectedURL.path) else {
            throw DatabaseAccessError.fileNotReadable
        }

        storeBookmark(for: selectedURL)
        log.debug("Successfully activated message service")
    }

    var isActivated: Bool {
        get async {
            let isActivated = canAccessDatabaseAtDefaultPath || canAccessDatabaseUsingBookmark
            log.debug("Message service activation status: \(isActivated)")
            return isActivated
        }
    }

    var tools: [Tool] {
        Tool(
            name: "messages_open",
            description:
                "Open a conversation in the Messages app. For group chats, finds and selects the existing conversation rather than creating a compose window.",
            inputSchema: .object(
                properties: [
                    "participants": .array(
                        description:
                            "Participant handles (phone or email). Phone numbers should use E.164 format",
                        items: .string()
                    )
                ],
                required: ["participants"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Open Messages Conversation",
                readOnlyHint: false,
                openWorldHint: true
            )
        ) { arguments in
            log.debug("Starting messages_open with arguments: \(arguments)")

            let participants =
                arguments["participants"]?.arrayValue?.compactMap({ $0.stringValue }) ?? []
            guard !participants.isEmpty else {
                throw DatabaseAccessError.invalidParticipants
            }

            if participants.count == 1 {
                let handle = participants[0]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = URL(string: "imessage://\(handle)") {
                    NSWorkspace.shared.open(url)
                }
                return [
                    "status": "opened",
                    "method": "url",
                ]
            }

            // Group chat: query Messages DB to find the existing conversation
            try await self.activate()
            let db = try self.createDatabaseConnection()
            let handles = try db.fetchParticipant(matching: participants)
            let chats = try db.fetchChats(with: Set(handles))

            guard chats.first(where: { Set($0.participants) == Set(handles) }) != nil else {
                // No existing group chat — open compose window as fallback
                let joined = participants.joined(separator: ",")
                if let url = URL(string: "imessage://\(joined)") {
                    NSWorkspace.shared.open(url)
                }
                return [
                    "status": "opened_compose",
                    "method": "url-compose",
                ]
            }

            // Build search terms: email local part or full phone number
            let searchTerms = participants.map { handle -> String in
                if let atIndex = handle.firstIndex(of: "@") {
                    return String(handle[handle.startIndex..<atIndex])
                }
                return handle
            }

            // AppleScript: activate Messages and click the group chat in the sidebar.
            // Group chats display as "Name1 & Name2..." so we look for text
            // containing "&" and at least one participant search term.
            let termsForScript = searchTerms
                .map { "\"\($0)\"" }
                .joined(separator: ", ")
            let source = """
                tell application "Messages" to activate
                delay 0.8
                tell application "System Events"
                    tell process "Messages"
                        set allElements to entire contents of window 1
                        repeat with anElement in allElements
                            try
                                if class of anElement is static text then
                                    set elementValue to value of anElement
                                    if elementValue contains "&" then
                                        repeat with aTerm in {\(termsForScript)}
                                            if elementValue contains aTerm then
                                                click anElement
                                                return "selected"
                                            end if
                                        end repeat
                                    end if
                                end if
                            end try
                        end repeat
                    end tell
                end tell
                return "not_found"
                """

            var scriptError: NSDictionary?
            let scriptResult = NSAppleScript(source: source)?
                .executeAndReturnError(&scriptError)
            let selected = scriptResult?.stringValue == "selected"

            if !selected {
                log.warning("Sidebar click failed: \(String(describing: scriptError))")
            }

            return [
                "status": selected ? "opened" : "fallback",
                "method": selected ? "sidebar-click" : "activate-only",
            ]
        }

        Tool(
            name: "messages_fetch",
            description: "Fetch messages from the Messages app",
            inputSchema: .object(
                properties: [
                    "participants": .array(
                        description:
                            "Participant handles (phone or email). Phone numbers should use E.164 format",
                        items: .string()
                    ),
                    "start": .string(
                        description:
                            "Start of the date range (inclusive). If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "End of the date range (exclusive). If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "query": .string(
                        description: "Search term to filter messages by content"
                    ),
                    "unread_only": .boolean(
                        description:
                            "If true, only return unread incoming messages (is_read = 0 and is_from_me = 0). Note: this is a best-effort approximation based on the Messages database and may not exactly match the Messages app badge count."
                    ),
                    "limit": .integer(
                        description: "Maximum messages to return",
                        default: .int(defaultLimit)
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Messages",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            log.debug("Starting message fetch with arguments: \(arguments)")
            try await self.activate()

            let participants =
                arguments["participants"]?.arrayValue?.compactMap({
                    $0.stringValue
                }) ?? []

            var dateRange: Range<Date>?
            if let startDateStr = arguments["start"]?.stringValue,
                let endDateStr = arguments["end"]?.stringValue,
                let parsedStart = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: startDateStr
                ),
                let parsedEnd = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: endDateStr
                )
            {
                let calendar = Calendar.current
                let normalizedStart = calendar.normalizedStartDate(
                    from: parsedStart.date,
                    isDateOnly: parsedStart.isDateOnly
                )
                let normalizedEnd = calendar.normalizedEndDate(
                    from: parsedEnd.date,
                    isDateOnly: parsedEnd.isDateOnly
                )

                dateRange = normalizedStart ..< normalizedEnd
            }

            let searchTerm = arguments["query"]?.stringValue
            let unreadOnly = arguments["unread_only"]?.boolValue ?? false
            let limit = arguments["limit"]?.intValue

            let db = try self.createDatabaseConnection()
            var messages: [[String: Value]] = []

            log.debug("Fetching handles for participants: \(participants)")
            let handles = try db.fetchParticipant(matching: participants)

            log.debug(
                "Fetching messages with date range: \(String(describing: dateRange)), unreadOnly: \(unreadOnly), limit: \(limit ?? -1)"
            )
            for message in try db.fetchMessages(
                with: Set(handles),
                in: dateRange,
                unreadOnly: unreadOnly,
                limit: max(limit ?? defaultLimit, 1024)
            ) {
                guard messages.count < (limit ?? defaultLimit) else { break }
                guard !message.text.isEmpty else { continue }

                let sender: String
                if message.isFromMe {
                    sender = "me"
                } else if message.sender == nil {
                    sender = "unknown"
                } else {
                    sender = message.sender!.rawValue
                }

                if let searchTerm {
                    guard message.text.localizedCaseInsensitiveContains(searchTerm) else {
                        continue
                    }
                }

                var entry: [String: Value] = [
                    "@id": .string(message.id.description),
                    "sender": [
                        "@id": .string(sender)
                    ],
                    "text": .string(message.text),
                    "createdAt": .string(message.date.formatted(.iso8601)),
                    "isRead": .bool(message.isRead),
                ]
                if let dateRead = message.dateRead {
                    entry["dateRead"] = .string(dateRead.formatted(.iso8601))
                }
                messages.append(entry)
            }

            log.debug("Successfully fetched \(messages.count) messages")
            return [
                "@context": "https://schema.org",
                "@type": "Conversation",
                "hasPart": Value.array(messages.map({ .object($0) })),
            ]
        }
    }

    private var canAccessDatabaseAtDefaultPath: Bool {
        return FileManager.default.isReadableFile(atPath: messagesDatabasePath)
    }

    private enum DatabaseAccessError: LocalizedError {
        case noBookmarkFound
        case securityScopeAccessFailed
        case invalidParticipants
        case userDeclinedAccess
        case invalidFileSelected
        case fileNotReadable

        var errorDescription: String? {
            switch self {
            case .noBookmarkFound:
                return "No stored bookmark found for database access"
            case .securityScopeAccessFailed:
                return "Failed to access security-scoped resource"
            case .invalidParticipants:
                return "Invalid participants provided"
            case .userDeclinedAccess:
                return "User declined to grant access to the messages database"
            case .invalidFileSelected:
                return "Messages database access denied or invalid file selected"
            case .fileNotReadable:
                return "Selected database file is not readable"
            }
        }
    }

    private func withSecurityScopedAccess<T>(_ url: URL, _ operation: (URL) throws -> T) throws -> T {
        guard url.startAccessingSecurityScopedResource() else {
            log.error("Failed to start accessing security-scoped resource")
            throw DatabaseAccessError.securityScopeAccessFailed
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try operation(url)
    }

    private func resolveBookmarkURL() throws -> URL {
        guard let bookmarkData = UserDefaults.standard.data(forKey: messagesDatabaseBookmarkKey)
        else {
            throw DatabaseAccessError.noBookmarkFound
        }

        var isStale = false
        return try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    private func createDatabaseConnection() throws -> iMessage.Database {
        if canAccessDatabaseAtDefaultPath {
            return try iMessage.Database()
        }

        let databaseURL = try resolveBookmarkURL()
        return try withSecurityScopedAccess(databaseURL) { url in
            try iMessage.Database(path: url.path)
        }
    }

    private var canAccessDatabaseUsingBookmark: Bool {
        do {
            let url = try resolveBookmarkURL()
            return try withSecurityScopedAccess(url) { url in
                FileManager.default.isReadableFile(atPath: url.path)
            }
        } catch {
            log.error("Error accessing database with bookmark: \(error.localizedDescription)")
            return false
        }
    }

    @MainActor
    private func showDatabaseAccessAlert() async throws -> Bool {
        let alert = NSAlert()
        alert.messageText = "Messages Database Access Required"
        alert.informativeText = """
            To read your Messages history, we need to open your database file.

            In the next screen, please select the file `chat.db` and click "Grant Access".
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private func showFilePicker() async throws -> URL {
        let openPanel = NSOpenPanel()
        openPanel.delegate = self
        openPanel.message = "Please select the Messages database file (chat.db)"
        openPanel.prompt = "Grant Access"
        openPanel.allowedContentTypes = [UTType.item]
        openPanel.directoryURL = URL(fileURLWithPath: messagesDatabasePath)
            .deletingLastPathComponent()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.showsHiddenFiles = true

        guard openPanel.runModal() == .OK,
            let url = openPanel.url,
            url.lastPathComponent == "chat.db"
        else {
            throw DatabaseAccessError.invalidFileSelected
        }

        return url
    }

    private func storeBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .securityScopeAllowOnlyReadAccess,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: messagesDatabaseBookmarkKey)
            log.debug("Successfully created and stored bookmark")
        } catch {
            log.error("Failed to create bookmark: \(error.localizedDescription)")
        }
    }

    // NSOpenSavePanelDelegate method to constrain file selection
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        let shouldEnable = url.lastPathComponent == "chat.db"
        log.debug(
            "File selection panel: \(shouldEnable ? "enabling" : "disabling") URL: \(url.path)"
        )
        return shouldEnable
    }
}
