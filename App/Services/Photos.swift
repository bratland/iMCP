import AppKit
import OSLog
import Photos
import SQLite3
import UniformTypeIdentifiers

private let log = Logger.service("photos")
private let defaultPhotosLibraryPath =
    "/Users/\(NSUserName())/Pictures/Photos Library.photoslibrary"
private let photosLibraryBookmarkKey = "me.mattt.iMCP.photosLibraryBookmark"
private let defaultLimit = 50
private let maxLimit = 500

final class PhotosService: NSObject, Service, NSOpenSavePanelDelegate {
    static let shared = PhotosService()

    // MARK: - Service

    var isActivated: Bool {
        get async {
            let photoKitAuthorized = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
            let librarySqliteReachable = canAccessLibraryAtDefaultPath || canAccessLibraryUsingBookmark
            return photoKitAuthorized && librarySqliteReachable
        }
    }

    func activate() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized else {
            throw PhotosAccessError.photoKitDenied
        }

        if canAccessLibraryAtDefaultPath {
            return
        }
        if canAccessLibraryUsingBookmark {
            return
        }

        guard try await showLibraryAccessAlert() else {
            throw PhotosAccessError.userDeclinedAccess
        }

        let selectedURL = try await showFilePicker()
        guard selectedURL.pathExtension == "photoslibrary" else {
            throw PhotosAccessError.invalidLibrarySelected
        }

        storeBookmark(for: selectedURL)
    }

    // MARK: - Tools

    var tools: [Tool] {
        Tool(
            name: "photos_fetch",
            description:
                "Fetch photo metadata from the Photos library via PhotoKit. Supports filtering by date range, media subtype (screenshot, live, panorama), favorites, and album name. Returns lightweight metadata only — use photos_export to write image files to disk.",
            inputSchema: .object(
                properties: [
                    "start": .string(
                        description: "Start of creation-date range (inclusive, ISO-8601).",
                        format: .dateTime
                    ),
                    "end": .string(
                        description: "End of creation-date range (exclusive, ISO-8601).",
                        format: .dateTime
                    ),
                    "mediaSubtype": .string(
                        description:
                            "Filter by media subtype.",
                        enum: ["screenshot", "panorama", "live", "hdr"]
                    ),
                    "favorites": .boolean(description: "If true, only favorited photos."),
                    "albumName": .string(description: "Restrict to a user album matching this title."),
                    "limit": .integer(default: .int(defaultLimit)),
                ],
                additionalProperties: false
            ),
            annotations: .init(title: "Fetch Photos", readOnlyHint: true, openWorldHint: false)
        ) { arguments in
            guard await self.isActivated else { throw PhotosAccessError.notActivated }

            let limit = min(max(arguments["limit"]?.intValue ?? defaultLimit, 1), maxLimit)
            let options = PHFetchOptions()
            options.fetchLimit = limit
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

            var predicates: [NSPredicate] = []
            if let startStr = arguments["start"]?.stringValue,
                let endStr = arguments["end"]?.stringValue,
                let start = ISO8601DateFormatter.parsedLenientISO8601Date(fromISO8601String: startStr)?.date,
                let end = ISO8601DateFormatter.parsedLenientISO8601Date(fromISO8601String: endStr)?.date
            {
                predicates.append(
                    NSPredicate(format: "creationDate >= %@ AND creationDate < %@", start as NSDate, end as NSDate)
                )
            }
            if arguments["favorites"]?.boolValue == true {
                predicates.append(NSPredicate(format: "favorite == YES"))
            }
            if let subtype = arguments["mediaSubtype"]?.stringValue {
                let mask: PHAssetMediaSubtype
                switch subtype {
                case "screenshot": mask = .photoScreenshot
                case "panorama": mask = .photoPanorama
                case "live": mask = .photoLive
                case "hdr": mask = .photoHDR
                default: mask = []
                }
                if !mask.isEmpty {
                    predicates.append(NSPredicate(format: "(mediaSubtypes & %d) != 0", mask.rawValue))
                }
            }
            if !predicates.isEmpty {
                options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            }

            let assets: PHFetchResult<PHAsset>
            if let albumName = arguments["albumName"]?.stringValue {
                let albumOptions = PHFetchOptions()
                albumOptions.predicate = NSPredicate(format: "localizedTitle == %@", albumName)
                let collections = PHAssetCollection.fetchAssetCollections(
                    with: .album, subtype: .any, options: albumOptions
                )
                guard let collection = collections.firstObject else {
                    return [
                        "@context": "https://schema.org",
                        "@type": "ItemList",
                        "numberOfItems": Value.int(0),
                        "itemListElement": Value.array([]),
                    ]
                }
                assets = PHAsset.fetchAssets(in: collection, options: options)
            } else {
                assets = PHAsset.fetchAssets(with: .image, options: options)
            }

            var items: [Value] = []
            assets.enumerateObjects { asset, _, _ in
                items.append(.object(asset.asValue()))
            }
            return [
                "@context": "https://schema.org",
                "@type": "ItemList",
                "numberOfItems": Value.int(items.count),
                "itemListElement": Value.array(items),
            ]
        }

        Tool(
            name: "photos_semantic_search",
            description:
                "Search the Photos library's on-device semantic index (the same one that powers the Photos app search bar). Queries classifications like 'receipt', 'document', 'food', 'screenshot'. Reads Photos.sqlite directly; schema may vary across macOS versions — call with probe=true first to inspect available tables.",
            inputSchema: .object(
                properties: [
                    "query": .string(description: "Scene/classification label (e.g. 'receipt', 'document')."),
                    "minConfidence": .number(description: "0.0 – 1.0 confidence threshold.", default: .double(0.5)),
                    "start": .string(format: .dateTime),
                    "end": .string(format: .dateTime),
                    "limit": .integer(default: .int(defaultLimit)),
                    "probe": .boolean(
                        description: "If true, returns the list of scene-classification tables/columns found in Photos.sqlite instead of running a search. Use once to adapt the query to your macOS version."
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(title: "Semantic Photo Search", readOnlyHint: true, openWorldHint: false)
        ) { arguments in
            guard await self.isActivated else { throw PhotosAccessError.notActivated }

            let dbURL = try self.resolveSqlitePath()
            return try self.withSecurityScopedAccess(self.libraryURL()) { _ in
                let db = try SQLiteReader(path: dbURL.path)
                defer { db.close() }

                if arguments["probe"]?.boolValue == true {
                    return try db.probeSceneTables()
                }

                guard let query = arguments["query"]?.stringValue, !query.isEmpty else {
                    throw PhotosAccessError.missingQuery
                }
                let minConfidence = arguments["minConfidence"]?.doubleValue ?? 0.5
                let limit = min(max(arguments["limit"]?.intValue ?? defaultLimit, 1), maxLimit)
                let start = arguments["start"]?.stringValue.flatMap {
                    ISO8601DateFormatter.parsedLenientISO8601Date(fromISO8601String: $0)?.date
                }
                let end = arguments["end"]?.stringValue.flatMap {
                    ISO8601DateFormatter.parsedLenientISO8601Date(fromISO8601String: $0)?.date
                }

                let uuids = try db.searchScenes(
                    label: query,
                    minConfidence: minConfidence,
                    start: start,
                    end: end,
                    limit: limit
                )

                // Hydrate via PhotoKit so we get stable metadata.
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: uuids.map { "\($0)/L0/001" }, options: nil)
                var items: [Value] = []
                assets.enumerateObjects { asset, _, _ in
                    items.append(.object(asset.asValue()))
                }

                return [
                    "@context": "https://schema.org",
                    "@type": "ItemList",
                    "numberOfItems": Value.int(items.count),
                    "itemListElement": Value.array(items),
                    "note": Value.string(
                        items.isEmpty
                            ? "No matches. Call with probe=true to inspect the schema on this macOS version."
                            : "Results from on-device Photos scene classifier."
                    ),
                ]
            }
        }

        Tool(
            name: "photos_export",
            description:
                "Export full-resolution images for the given Photos localIdentifiers to a folder on disk. Returns the destination path and per-asset file paths. Use this to bypass MCP transport size limits.",
            inputSchema: .object(
                properties: [
                    "localIdentifiers": .array(
                        description: "PhotoKit localIdentifiers returned by photos_fetch or photos_semantic_search.",
                        items: .string()
                    ),
                    "destination": .string(
                        description:
                            "Destination directory. Expands ~. Defaults to ~/Documents/iMCP-exports/photos-<timestamp>."
                    ),
                ],
                required: ["localIdentifiers"],
                additionalProperties: false
            ),
            annotations: .init(title: "Export Photos", readOnlyHint: false, openWorldHint: false)
        ) { arguments in
            guard await self.isActivated else { throw PhotosAccessError.notActivated }
            guard let ids = arguments["localIdentifiers"]?.arrayValue?.compactMap({ $0.stringValue }),
                !ids.isEmpty
            else {
                throw PhotosAccessError.missingIdentifiers
            }

            let destDir = try self.resolveDestination(argument: arguments["destination"]?.stringValue)
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

            let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var exported: [Value] = []
            var failures: [Value] = []

            for i in 0..<assets.count {
                let asset = assets.object(at: i)
                do {
                    let url = try await self.exportAsset(asset, into: destDir)
                    exported.append(
                        .object([
                            "@id": .string(asset.localIdentifier),
                            "path": .string(url.path),
                        ])
                    )
                } catch {
                    failures.append(
                        .object([
                            "@id": .string(asset.localIdentifier),
                            "error": .string(error.localizedDescription),
                        ])
                    )
                }
            }

            return [
                "destination": Value.string(destDir.path),
                "exportedCount": Value.int(exported.count),
                "failedCount": Value.int(failures.count),
                "exported": Value.array(exported),
                "failed": Value.array(failures),
            ]
        }
    }

    // MARK: - Library access (bookmark + sandbox)

    private var canAccessLibraryAtDefaultPath: Bool {
        FileManager.default.isReadableFile(
            atPath: defaultPhotosLibraryPath + "/database/Photos.sqlite"
        )
    }

    private var canAccessLibraryUsingBookmark: Bool {
        do {
            let url = try resolveBookmarkURL()
            return try withSecurityScopedAccess(url) { url in
                FileManager.default.isReadableFile(
                    atPath: url.appendingPathComponent("database/Photos.sqlite").path
                )
            }
        } catch {
            log.error("Error accessing Photos library with bookmark: \(error.localizedDescription)")
            return false
        }
    }

    private func libraryURL() throws -> URL {
        if canAccessLibraryAtDefaultPath {
            return URL(fileURLWithPath: defaultPhotosLibraryPath)
        }
        return try resolveBookmarkURL()
    }

    private func resolveSqlitePath() throws -> URL {
        try libraryURL().appendingPathComponent("database/Photos.sqlite")
    }

    private func resolveBookmarkURL() throws -> URL {
        guard let data = UserDefaults.standard.data(forKey: photosLibraryBookmarkKey) else {
            throw PhotosAccessError.noBookmarkFound
        }
        var isStale = false
        return try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    private func withSecurityScopedAccess<T>(_ url: URL, _ op: (URL) throws -> T) throws -> T {
        guard url.startAccessingSecurityScopedResource() else {
            throw PhotosAccessError.securityScopeFailed
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try op(url)
    }

    private func storeBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(
                options: .securityScopeAllowOnlyReadAccess,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: photosLibraryBookmarkKey)
        } catch {
            log.error("Failed to store Photos bookmark: \(error.localizedDescription)")
        }
    }

    // MARK: - UI prompts

    @MainActor
    private func showLibraryAccessAlert() async throws -> Bool {
        let alert = NSAlert()
        alert.messageText = "Photos Library Access Required"
        alert.informativeText = """
            iMCP needs to read the Photos library's semantic search index (the same one Photos.app uses to find "receipts", "documents", etc.).

            Please select your Photos library package (typically named "Photos Library.photoslibrary" in your Pictures folder).
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private func showFilePicker() async throws -> URL {
        let panel = NSOpenPanel()
        panel.delegate = self
        panel.message = "Select your Photos Library (.photoslibrary)"
        panel.prompt = "Grant Access"
        panel.allowedContentTypes = [UTType.package, UTType.directory]
        panel.directoryURL = URL(fileURLWithPath: defaultPhotosLibraryPath).deletingLastPathComponent()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.showsHiddenFiles = false
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK, let url = panel.url,
            url.pathExtension == "photoslibrary"
        else {
            throw PhotosAccessError.invalidLibrarySelected
        }
        return url
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        url.pathExtension == "photoslibrary"
    }

    // MARK: - Export

    private func resolveDestination(argument: String?) throws -> URL {
        if let raw = argument, !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded)
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iMCP-exports/photos-\(stamp)")
    }

    private func exportAsset(_ asset: PHAsset, into directory: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.version = .current
            options.deliveryMode = .highQualityFormat

            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) {
                data, uti, _, info in
                if let err = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: err)
                    return
                }
                guard let data else {
                    continuation.resume(throwing: PhotosAccessError.exportFailed)
                    return
                }
                let ext =
                    (uti.flatMap { UTType($0) }?.preferredFilenameExtension)
                    ?? (asset.mediaSubtypes.contains(.photoScreenshot) ? "png" : "jpg")
                let safeID = asset.localIdentifier
                    .replacingOccurrences(of: "/", with: "_")
                let url = directory.appendingPathComponent("\(safeID).\(ext)")
                do {
                    try data.write(to: url)
                    continuation.resume(returning: url)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Errors

private enum PhotosAccessError: LocalizedError {
    case photoKitDenied
    case noBookmarkFound
    case securityScopeFailed
    case userDeclinedAccess
    case invalidLibrarySelected
    case notActivated
    case missingQuery
    case missingIdentifiers
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .photoKitDenied: return "Photos access was denied in System Settings."
        case .noBookmarkFound: return "No stored bookmark for Photos library."
        case .securityScopeFailed: return "Failed to access security-scoped Photos library."
        case .userDeclinedAccess: return "User declined access to the Photos library."
        case .invalidLibrarySelected: return "Selected file is not a .photoslibrary package."
        case .notActivated: return "Photos service is not activated."
        case .missingQuery: return "A 'query' argument is required."
        case .missingIdentifiers: return "At least one localIdentifier is required."
        case .exportFailed: return "Failed to export image data."
        }
    }
}

// MARK: - Ontology mapping

extension PHAsset {
    fileprivate func asValue() -> [String: Value] {
        var obj: [String: Value] = [
            "@id": .string(localIdentifier),
            "@type": .string(mediaType == .video ? "VideoObject" : "ImageObject"),
            "width": .int(pixelWidth),
            "height": .int(pixelHeight),
            "isFavorite": .bool(isFavorite),
        ]
        if let created = creationDate {
            obj["dateCreated"] = .string(created.formatted(.iso8601))
        }
        if let modified = modificationDate {
            obj["dateModified"] = .string(modified.formatted(.iso8601))
        }
        if let loc = location {
            obj["contentLocation"] = .object([
                "@type": .string("Place"),
                "geo": .object([
                    "@type": .string("GeoCoordinates"),
                    "latitude": .double(loc.coordinate.latitude),
                    "longitude": .double(loc.coordinate.longitude),
                ]),
            ])
        }
        var subtypes: [String] = []
        if mediaSubtypes.contains(.photoScreenshot) { subtypes.append("screenshot") }
        if mediaSubtypes.contains(.photoPanorama) { subtypes.append("panorama") }
        if mediaSubtypes.contains(.photoLive) { subtypes.append("live") }
        if mediaSubtypes.contains(.photoHDR) { subtypes.append("hdr") }
        if !subtypes.isEmpty {
            obj["additionalType"] = .array(subtypes.map { .string($0) })
        }
        return obj
    }
}

// MARK: - SQLite reader (scene classification)

/// Minimal SQLite helper for probing/reading the Photos semantic index.
/// The Photos.sqlite schema changes between macOS versions; use `probeSceneTables()`
/// to discover available tables/columns on the current system.
private final class SQLiteReader {
    private var handle: OpaquePointer?

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db { sqlite3_close(db) }
            throw NSError(
                domain: "PhotosService", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "sqlite open failed: \(msg)"]
            )
        }
        self.handle = db
    }

    func close() {
        if let handle { sqlite3_close(handle) }
        handle = nil
    }

    /// Returns a JSON-friendly map of scene/classification-related tables and their columns.
    func probeSceneTables() throws -> Value {
        let tables = try queryStrings(
            sql:
                "SELECT name FROM sqlite_master WHERE type='table' AND (name LIKE '%SCENE%' OR name LIKE '%CLASSIFICATION%' OR name LIKE '%CATEGORY%' OR name LIKE '%LABEL%') ORDER BY name"
        )
        var result: [String: Value] = [:]
        for table in tables {
            let cols = try queryStrings(sql: "SELECT name FROM pragma_table_info('\(table)')")
            result[table] = .array(cols.map { .string($0) })
        }
        return .object([
            "tables": .object(result),
            "hint": .string(
                "Send this output back so the semantic search query can be adapted to your macOS version."
            ),
        ])
    }

    /// Best-effort scene search. Tries known schemas (macOS 14/15/26) in order.
    /// Returns asset UUIDs (without the /L0/001 suffix).
    func searchScenes(
        label: String, minConfidence: Double, start: Date?, end: Date?, limit: Int
    ) throws -> [String] {
        // Core Data "reference date" epoch: 2001-01-01 00:00:00 UTC
        let refEpoch = Date(timeIntervalSinceReferenceDate: 0).timeIntervalSince1970
        let startSec = start.map { $0.timeIntervalSince1970 - refEpoch }
        let endSec = end.map { $0.timeIntervalSince1970 - refEpoch }

        // Schema attempt 1: ZSCENECLASSIFICATION + ZSCENEIDENTIFIER (macOS 13–15)
        let sql1 = """
            SELECT DISTINCT a.ZUUID
            FROM ZASSET a
            JOIN ZSCENECLASSIFICATION sc ON sc.ZASSET = a.Z_PK
            JOIN ZSCENEIDENTIFIER si ON si.Z_PK = sc.ZSCENEIDENTIFIER
            WHERE LOWER(si.ZLABEL) = LOWER(?)
              AND sc.ZCONFIDENCE >= ?
              \(startSec != nil ? "AND a.ZDATECREATED >= ?" : "")
              \(endSec != nil ? "AND a.ZDATECREATED < ?" : "")
              AND a.ZTRASHEDSTATE = 0
            ORDER BY a.ZDATECREATED DESC
            LIMIT ?
            """
        if let rows = try? runScenesQuery(
            sql: sql1, label: label, minConfidence: minConfidence,
            startSec: startSec, endSec: endSec, limit: limit), !rows.isEmpty
        {
            return rows
        }

        // Schema attempt 2: flattened ZSCENE (older layouts)
        let sql2 = """
            SELECT DISTINCT a.ZUUID
            FROM ZASSET a
            JOIN ZSCENE s ON s.ZASSET = a.Z_PK
            WHERE LOWER(s.ZLABEL) = LOWER(?)
              AND s.ZCONFIDENCE >= ?
              \(startSec != nil ? "AND a.ZDATECREATED >= ?" : "")
              \(endSec != nil ? "AND a.ZDATECREATED < ?" : "")
              AND a.ZTRASHEDSTATE = 0
            ORDER BY a.ZDATECREATED DESC
            LIMIT ?
            """
        if let rows = try? runScenesQuery(
            sql: sql2, label: label, minConfidence: minConfidence,
            startSec: startSec, endSec: endSec, limit: limit), !rows.isEmpty
        {
            return rows
        }

        return []
    }

    private func runScenesQuery(
        sql: String, label: String, minConfidence: Double,
        startSec: Double?, endSec: Double?, limit: Int
    ) throws -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "PhotosService", code: 2,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))]
            )
        }
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        sqlite3_bind_text(stmt, idx, label, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        idx += 1
        sqlite3_bind_double(stmt, idx, minConfidence)
        idx += 1
        if let startSec {
            sqlite3_bind_double(stmt, idx, startSec)
            idx += 1
        }
        if let endSec {
            sqlite3_bind_double(stmt, idx, endSec)
            idx += 1
        }
        sqlite3_bind_int(stmt, idx, Int32(limit))

        var results: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cstr = sqlite3_column_text(stmt, 0) {
                results.append(String(cString: cstr))
            }
        }
        return results
    }

    private func queryStrings(sql: String) throws -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "PhotosService", code: 3,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))]
            )
        }
        defer { sqlite3_finalize(stmt) }
        var results: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cstr = sqlite3_column_text(stmt, 0) {
                results.append(String(cString: cstr))
            }
        }
        return results
    }
}
