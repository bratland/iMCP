import AppKit
import JSONSchema
import MCP
import OSLog

private let log = Logger.service("clipboard")

/// Error types for clipboard operations.
enum ClipboardError: LocalizedError {
    case missingContent
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .missingContent:
            return "Missing required 'content' parameter"
        case .writeFailed:
            return "Failed to write content to clipboard"
        }
    }
}

final class ClipboardService: Service {
    static let shared = ClipboardService()

    var tools: [Tool] {
        Tool(
            name: "clipboard_read",
            description:
                "Read the current clipboard contents. Returns text, image data, or file URLs depending on what's in the clipboard.",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Read Clipboard",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            try await self.readClipboard()
        }

        Tool(
            name: "clipboard_write",
            description: "Write text content to the clipboard, replacing any existing content.",
            inputSchema: .object(
                properties: [
                    "content": .string(description: "Text content to write to clipboard")
                ],
                required: ["content"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Write to Clipboard",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.writeClipboard(arguments: arguments)
        }

        Tool(
            name: "clipboard_types",
            description: "List available data types in the current clipboard.",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Clipboard Types",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            try await self.listClipboardTypes()
        }
    }

    // MARK: - Private Implementation

    @MainActor
    private func readClipboard() async throws -> Value {
        let pasteboard = NSPasteboard.general
        let types = pasteboard.types ?? []

        // Priority: files → image → text
        // Files first because Finder copies include both file URL and filename as text

        // Check for file URLs (copied files from Finder)
        if types.contains(.fileURL),
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
            !urls.isEmpty
        {
            log.debug("Clipboard contains \(urls.count) file URLs")
            return .object([
                "type": .string("files"),
                "urls": .array(urls.map { .string($0.absoluteString) }),
                "filenames": .array(urls.map { .string($0.lastPathComponent) }),
            ])
        }

        // Check for image data (TIFF is the standard macOS image format)
        if let imageData = pasteboard.data(forType: .tiff) {
            log.debug("Clipboard contains image (\(imageData.count) bytes)")
            return .data(mimeType: "image/tiff", imageData)
        }

        // Check for PNG image
        if let imageData = pasteboard.data(forType: .png) {
            log.debug("Clipboard contains PNG image (\(imageData.count) bytes)")
            return .data(mimeType: "image/png", imageData)
        }

        // Fallback to text
        if let string = pasteboard.string(forType: .string) {
            log.debug("Clipboard contains text (\(string.count) characters)")
            return .object([
                "type": .string("text"),
                "content": .string(string),
            ])
        }

        log.debug("Clipboard is empty")
        return .object([
            "type": .string("empty"),
            "content": .null,
        ])
    }

    @MainActor
    private func writeClipboard(arguments: [String: Value]) async throws -> Value {
        guard let content = arguments["content"]?.stringValue else {
            log.error("clipboard_write called without content parameter")
            throw ClipboardError.missingContent
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let success = pasteboard.setString(content, forType: .string)

        if success {
            log.info("Wrote \(content.count) characters to clipboard")
        } else {
            log.error("Failed to write to clipboard")
        }

        return .object([
            "success": .bool(success),
            "length": .int(content.count),
        ])
    }

    @MainActor
    private func listClipboardTypes() async throws -> Value {
        let pasteboard = NSPasteboard.general
        let types = pasteboard.types ?? []

        log.debug("Clipboard has \(types.count) types available")

        return .object([
            "types": .array(types.map { .string($0.rawValue) }),
            "count": .int(types.count),
        ])
    }
}
