# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Build the app (Release configuration)
xcodebuild -scheme iMCP -configuration Release -destination "platform=macOS" build

# Build for development (Debug)
xcodebuild -scheme iMCP -configuration Debug -destination "platform=macOS" build

# Release workflow (requires signing credentials)
Scripts/release.sh check    # Quick release build check
Scripts/release.sh bump     # Bump version (requires VERSION env var)
Scripts/release.sh archive  # Create Xcode archive
Scripts/release.sh all      # Full release pipeline
```

## Code Formatting

Uses swift-format with 4-space indentation and 120 character line length:
```bash
swift-format format --in-place --recursive Sources/
```

## Architecture Overview

### Two-Component Design

iMCP consists of two executables that communicate via Bonjour (local network discovery):

1. **App** (`/App/`) — macOS menu bar application
   - Manages system permissions (Contacts, Calendar, Location, etc.)
   - Hosts the MCP server via `ServerController` → `ServerNetworkManager`
   - Advertises service as `_mcp._tcp` on local domain
   - Shows connection approval UI for new clients

2. **CLI** (`/CLI/main.swift`) — Stdio-to-network proxy (`imcp-server`)
   - Used by MCP clients (Claude Desktop, Cursor, etc.)
   - `StdioProxy` actor bridges stdin/stdout ↔ network connection
   - Discovers App via Bonjour, forwards JSON-RPC messages

### Service System

Services are defined in `/App/Services/` and expose MCP tools:

```swift
final class CalendarService: Service {
    static let shared = CalendarService()

    var isActivated: Bool { ... }  // Check permission status
    func activate() async throws { ... }  // Request permission

    var tools: [Tool] {
        Tool(name: "events_fetch", ...) { arguments in ... }
        Tool(name: "events_create", ...) { arguments in ... }
    }
}
```

- `Service` protocol (`/App/Models/Service.swift`) — defines `tools`, `isActivated`, `activate()`
- `@ToolBuilder` result builder for declaring tools
- `Tool` struct wraps name, schema, annotations, and async implementation
- `ServiceRegistry` in ServerController registers all services with UI bindings

### Key Actors

- `ServerNetworkManager` — manages listener, connections, and tool registration
- `MCPConnectionManager` — handles single MCP connection lifecycle
- `NetworkDiscoveryManager` — Bonjour advertisement/discovery
- `StdioProxy` (CLI) — bidirectional stdin/stdout ↔ network forwarding

### Data Encoding

Tool results use JSON-LD format via the [Ontology](https://github.com/mattt/Ontology) package:
- Schema.org types (Person, Event, Place, etc.)
- `Value` enum (`/App/Models/Value.swift`) for type-safe JSON handling
- Timezone-aware encoding via `DateTime.timeZoneOverrideKey`

### Dependencies

External packages (referenced in Xcode project):
- [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) — MCP protocol implementation
- [Ontology](https://github.com/mattt/Ontology) — JSON-LD structured data
- [Madrid](https://github.com/mattt/Madrid) — iMessage database reading
- MenuBarExtraAccess — SwiftUI menu bar utilities

### Weather Service

`WeatherService` requires WeatherKit entitlement and is conditionally compiled:
```swift
#if WEATHERKIT_AVAILABLE
    services.append(WeatherService.shared)
#endif
```

## Adding a New Service

1. Create service class in `/App/Services/YourService.swift`
2. Implement `Service` protocol with `tools` property using `@ToolBuilder`
3. Add to `ServiceRegistry.services` array in `ServerController.swift`
4. Add `@AppStorage` binding and `ServiceConfig` entry in `ServerController`
5. Tool results should use Ontology types or `Value` enum

## Notes

- Ignore spurious SourceKit warnings about missing types/modules — assume types exist
- Don't attempt to install new Swift packages
- Messages service reads `~/Library/Messages/chat.db` via sandbox-extended file picker
