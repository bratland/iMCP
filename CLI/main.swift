import Logging
import MCP
import Network
import ServiceLifecycle
import SystemPackage

import struct Foundation.Data
import class Foundation.JSONSerialization
import class Foundation.RunLoop

var log = Logger(label: "me.mattt.iMCP.server") { StreamLogHandler.standardError(label: $0) }
#if DEBUG
    log.logLevel = .debug
#else
    log.logLevel = .warning
#endif

// Network setup
let serviceType = "_mcp._tcp"
let parameters = NWParameters.tcp
parameters.acceptLocalOnly = true
parameters.includePeerToPeer = false

if let tcpOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
    tcpOptions.version = .v4
}

// Detect half-open connections (e.g. after system sleep): without keepalive a dead peer is
// never noticed and the proxy waits on receive() forever. With these settings a dead
// connection fails within ~25 seconds (10s idle + 3 probes * 5s).
if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
    tcpOptions.enableKeepalive = true
    tcpOptions.keepaliveIdle = 10
    tcpOptions.keepaliveInterval = 5
    tcpOptions.keepaliveCount = 3
}

// Create browser at top level
let browser = NWBrowser(
    for: .bonjour(type: serviceType, domain: nil),
    using: parameters
)
log.info("Created Bonjour browser for service type: \(serviceType)")

actor ConnectionState {
    private var hasResumed = false

    func checkAndSetResumed() -> Bool {
        if !hasResumed {
            hasResumed = true
            return true
        }
        return false
    }
}

/// An actor that provides a configurable proxy between standard I/O and network connections
actor StdioProxy {
    // Connection configuration
    private let endpoint: NWEndpoint
    private let parameters: NWParameters
    private let stdinBufferSize: Int
    private let networkBufferSize: Int

    // Connection state
    private var connection: NWConnection?
    private var isRunning = false

    // Message buffering for proper JSON-RPC message boundaries
    private var networkToStdoutBuffer = Data()

    // Response watchdog: timestamps of forwarded requests still awaiting a response.
    // Slightly longer than the app's 30-second tool timeout so a live app always gets to
    // answer first; this only fires when the transport itself has gone dead.
    private let responseTimeout: Duration = .seconds(35)
    private var stdinParseBuffer = Data()
    private var pendingRequestStarts: [ContinuousClock.Instant] = []

    /// Creates a new StdioProxy with the specified network configuration
    /// - Parameters:
    ///   - endpoint: The network endpoint to connect to
    ///   - parameters: Network connection parameters
    ///   - stdinBufferSize: Buffer size for reading from stdin (default: 4096)
    ///   - networkBufferSize: Buffer size for reading from network (default: 4096)
    init(
        endpoint: NWEndpoint,
        parameters: NWParameters = .tcp,
        stdinBufferSize: Int = 10 * 1024 * 1024,
        networkBufferSize: Int = 10 * 1024 * 1024
    ) {
        self.endpoint = endpoint
        self.parameters = parameters
        self.stdinBufferSize = stdinBufferSize
        self.networkBufferSize = networkBufferSize
    }

    /// Starts the proxy
    func start() async throws {
        guard !isRunning else { return }
        isRunning = true

        // Create the connection
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection

        // Wait for the connection to become ready.
        //
        // The state handler is installed *before* `connection.start()` and both run inside the
        // same synchronous continuation closure. This is required to avoid a lost-wakeup deadlock:
        // if the connection were started first, a `.ready` (or `.failed`) state delivered on the
        // main queue could fire before the continuation handler is installed, and the continuation
        // would never be resumed, hanging the proxy forever.
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Swift.Error>) in
            let connectionState = ConnectionState()
            connection.stateUpdateHandler = { state in
                Task { [weak self] in
                    await self?.handleConnectionState(
                        state,
                        continuation: continuation,
                        connectionState: connectionState
                    )
                }
            }
            connection.start(queue: .main)
        }

        // Replace the setup handler with a lifetime monitor. The continuation has already been
        // consumed (guarded by ConnectionState), so further state changes only drive teardown.
        connection.stateUpdateHandler = { state in
            Task { [weak self] in
                await self?.handleConnectionState(state, continuation: nil, connectionState: nil)
            }
        }

        // Create a structured concurrency task group for handling I/O
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Add task for handling stdin to network
            group.addTask { [stdinBufferSize] in
                do {
                    try await self.handleStdinToNetwork(bufferSize: stdinBufferSize)
                } catch {
                    await log.error("Stdin handler failed: \(error)")
                    throw error
                }
            }

            // Add task for handling network to stdout
            group.addTask { [networkBufferSize] in
                do {
                    try await self.handleNetworkToStdout(bufferSize: networkBufferSize)
                } catch {
                    await log.error("Network handler failed: \(error)")
                    throw error
                }
            }

            // Watchdog: fail fast when a forwarded request never gets a response.
            group.addTask {
                try await self.runResponseWatchdog()
            }

            // Wait for any task to complete (or fail). On both paths the connection must be
            // cancelled via stop() *before* the group is awaited: handlers blocked in
            // send/receive continuations are not cancellation-aware and only unblock when
            // the connection delivers their callback with an error.
            do {
                try await group.next()
            } catch {
                group.cancelAll()
                await self.stop()
                throw error
            }
            await log.debug("A task completed, cancelling remaining tasks")

            // If we get here, one of the tasks completed or failed
            // Cancel all remaining tasks
            group.cancelAll()

            // Stop the proxy
            await self.stop()
        }
    }

    /// Stops the proxy and cleans up resources
    func stop() async {
        isRunning = false
        connection?.cancel()
        connection = nil
    }

    /// Handles connection state changes
    private func handleConnectionState(
        _ state: NWConnection.State,
        continuation: CheckedContinuation<Void, Swift.Error>?,
        connectionState: ConnectionState?
    ) async {
        switch state {
        case .ready:
            await log.debug("Connection established to \(endpoint)")
            if await shouldResume(connectionState: connectionState) {
                continuation?.resume()
            }
        case .failed(let error):
            await log.debug("Connection failed: \(error)")
            if let continuation = continuation,
                await shouldResume(connectionState: connectionState)
            {
                continuation.resume(throwing: error)
            }
            await stop()
        case .cancelled:
            await log.debug("Connection cancelled")
            if let continuation = continuation,
                await shouldResume(connectionState: connectionState)
            {
                continuation.resume(throwing: CancellationError())
            }
            await stop()
        case .waiting(let error):
            await log.debug("Connection waiting: \(error)")
        case .preparing:
            await log.debug("Connection preparing...")
        case .setup:
            await log.debug("Connection setup...")
        @unknown default:
            await log.debug("Unknown connection state")
        }
    }

    /// Records outbound JSON-RPC requests (messages with both "method" and "id") so the
    /// watchdog can detect a transport that has stopped delivering responses.
    private func trackOutboundRequests(in data: Data) {
        stdinParseBuffer.append(data)
        while let newlineIndex = stdinParseBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = Data(stdinParseBuffer[..<newlineIndex])
            stdinParseBuffer = stdinParseBuffer[(newlineIndex + 1)...]
            guard
                let message = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                message["method"] != nil, message["id"] != nil
            else { continue }
            pendingRequestStarts.append(ContinuousClock.now)
        }
    }

    /// Settles the oldest pending request when a server response arrives.
    private func trackInboundResponse(in messageData: Data) {
        guard !pendingRequestStarts.isEmpty,
            let message = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
            message["id"] != nil, message["method"] == nil
        else { return }
        pendingRequestStarts.removeFirst()
    }

    /// Fails the proxy when a forwarded request has gone unanswered for too long. This catches
    /// dead transports that TCP keepalive misses; terminating lets the MCP client fail the
    /// pending call and respawn the proxy instead of hanging indefinitely.
    private func runResponseWatchdog() async throws {
        while true {
            try await Task.sleep(for: .seconds(1))
            guard isRunning else { return }
            if let oldest = pendingRequestStarts.first,
                ContinuousClock.now - oldest > responseTimeout
            {
                await log.error(
                    "No response from iMCP app within \(responseTimeout), closing connection")
                throw StdioProxyError.responseTimeout
            }
        }
    }

    private func shouldResume(connectionState: ConnectionState?) async -> Bool {
        if let connectionState = connectionState {
            return await connectionState.checkAndSetResumed()
        }
        return true
    }

    private func setNonBlocking(fileDescriptor: FileDescriptor) throws {
        let flags = fcntl(fileDescriptor.rawValue, F_GETFL)
        guard flags >= 0 else {
            throw MCPError.transportError(Errno.badFileDescriptor)
        }
        let result = fcntl(fileDescriptor.rawValue, F_SETFL, flags | O_NONBLOCK)
        guard result >= 0 else {
            throw MCPError.transportError(Errno.badFileDescriptor)
        }
    }

    /// Handles forwarding data from stdin to the network
    private func handleStdinToNetwork(bufferSize: Int) async throws {
        let stdin = FileDescriptor.standardInput
        try setNonBlocking(fileDescriptor: stdin)

        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var pendingData = Data()

        while true {
            // Check connection state at the beginning of each loop iteration
            guard isRunning, let connection = self.connection else {
                await log.debug("Connection no longer active, stopping stdin handler")
                throw StdioProxyError.connectionClosed
            }

            // Also check connection state
            if connection.state != .ready && connection.state != .preparing {
                await log.debug(
                    "Connection state changed to \(connection.state), stopping stdin handler"
                )
                throw StdioProxyError.connectionClosed
            }

            do {
                // Read data from stdin using SystemPackage approach
                let bytesRead = try buffer.withUnsafeMutableBufferPointer { pointer in
                    try stdin.read(into: UnsafeMutableRawBufferPointer(pointer))
                }

                if bytesRead == 0 {
                    // EOF reached
                    await log.debug("EOF reached on stdin, stopping stdin handler")
                    break
                }

                if bytesRead > 0 {
                    // Append the read bytes to pending data
                    pendingData.append(contentsOf: buffer[0 ..< bytesRead])

                    // Check if the data is only whitespace
                    let isOnlyWhitespace = pendingData.allSatisfy {
                        let char = Character(UnicodeScalar($0))
                        return char.isWhitespace || char.isNewline
                    }

                    // Only send if we have non-whitespace content
                    if !isOnlyWhitespace && !pendingData.isEmpty {
                        // Send data to the network connection
                        try await withCheckedThrowingContinuation {
                            (continuation: CheckedContinuation<Void, Swift.Error>) in
                            connection.send(
                                content: pendingData,
                                completion: .contentProcessed { error in
                                    if let error = error {
                                        continuation.resume(throwing: error)
                                    } else {
                                        continuation.resume()
                                    }
                                }
                            )
                        }

                        await log.debug("Sent \(pendingData.count) bytes to network")
                        trackOutboundRequests(in: pendingData)
                    } else if isOnlyWhitespace && !pendingData.isEmpty {
                        await log.trace(
                            "Skipping send of \(pendingData.count) whitespace-only bytes"
                        )
                    }

                    // Clear pending data after processing
                    pendingData.removeAll(keepingCapacity: true)
                }
            } catch {
                if let posixError = error as? Errno, posixError == .wouldBlock {
                    try await Task.sleep(for: .milliseconds(10))  // Keep the sleep to yield CPU
                    continue
                }

                await log.error("Error in stdin handler: \(error)")
                throw error
            }
        }

        await log.debug("Stdin handler task completed")
    }

    /// Handles forwarding data from the network to stdout
    private func handleNetworkToStdout(bufferSize: Int) async throws {
        let stdout = FileDescriptor.standardOutput
        var consecutiveEmptyReads = 0
        let maxConsecutiveEmptyReads = 100  // After this many consecutive empty reads, we'll check connection state

        while true {
            // Check connection state at the beginning of each loop iteration
            guard isRunning, let connection = self.connection else {
                await log.debug("Connection no longer active, stopping network handler")
                throw StdioProxyError.connectionClosed
            }

            // Also check connection state
            if connection.state != .ready && connection.state != .preparing {
                await log.debug(
                    "Connection state changed to \(connection.state), stopping network handler"
                )
                throw StdioProxyError.connectionClosed
            }

            do {
                // Check connection state periodically if we're getting consecutive empty reads
                if consecutiveEmptyReads > 0
                    && consecutiveEmptyReads % maxConsecutiveEmptyReads == 0
                {
                    // If we've had too many empty reads, consider it a timeout
                    if consecutiveEmptyReads > maxConsecutiveEmptyReads * 10 {
                        await log.warning(
                            "Network read timed out after \(consecutiveEmptyReads) consecutive empty reads"
                        )
                        throw StdioProxyError.networkTimeout
                    }
                }

                // Receive data from the network connection
                let data = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Data, Swift.Error>) in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: bufferSize) {
                        data,
                        _,
                        isComplete,
                        error in
                        if let error = error {
                            continuation.resume(throwing: error)
                            return
                        }

                        if let data = data {
                            continuation.resume(returning: data)
                        } else if isComplete {
                            log.debug("Network connection complete")
                            continuation.resume(throwing: StdioProxyError.connectionClosed)
                        } else {
                            continuation.resume(returning: Data())
                        }
                    }
                }

                var processedData = data

                // Check for and filter out heartbeat messages using MCP.NetworkTransport.Heartbeat
                // Assuming MCP module and NetworkTransport.Heartbeat are available
                if NetworkTransport.Heartbeat.isHeartbeat(processedData) {
                    await log.debug(
                        "Heartbeat signature detected in received network data using MCP definition."
                    )

                    // Try to parse a full heartbeat. MCP.NetworkTransport.Heartbeat.from(data:) checks for minimum length internally.
                    if let heartbeat = NetworkTransport.Heartbeat.from(data: processedData) {
                        let heartbeatLength = heartbeat.rawValue.count  // This should typically be 12
                        await log.debug(
                            "Full MCP heartbeat message (\(heartbeatLength) bytes) received from network, skipping output."
                        )
                        // Remove the full heartbeat from the data
                        processedData = processedData.dropFirst(heartbeatLength)
                    } else {
                        // MCP.NetworkTransport.Heartbeat.isHeartbeat was true, but .from(data:) failed.
                        // This means we have the magic bytes but not the full message (e.g., data length < 12 but >= 4).
                        let expectedHeartbeatLength = MCP.NetworkTransport.Heartbeat().rawValue
                            .count  // Get expected length (12)
                        await log.debug(
                            "Partial MCP heartbeat message (<\(expectedHeartbeatLength) bytes) received, discarding this chunk to prevent garbled output."
                        )
                        processedData = Data()  // Discard the chunk
                    }
                }

                if processedData.isEmpty {
                    // No data available (or entire chunk was a heartbeat), yield to other tasks
                    // If original data was not empty, but processedData is, it means it was a heartbeat.
                    if !data.isEmpty {  // Original data was not empty, so this was a heartbeat
                        consecutiveEmptyReads = 0  // Reset counter as we did receive something (a heartbeat)
                    } else {
                        consecutiveEmptyReads += 1
                    }
                    try await Task.sleep(for: .milliseconds(10))
                    continue
                } else {
                    // Reset counter when we get actual data (not just a heartbeat)
                    consecutiveEmptyReads = 0
                    await log.debug(
                        "Received \(processedData.count) bytes of application data from network"
                    )
                }

                // Add data to buffer for message assembly
                networkToStdoutBuffer.append(processedData)

                // Process complete messages (delimited by newlines)
                while let newlineIndex = networkToStdoutBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let messageData = networkToStdoutBuffer[..<newlineIndex]
                    var messageWithNewline = Data(messageData)
                    messageWithNewline.append(UInt8(ascii: "\n"))

                    // Remove processed message from buffer
                    networkToStdoutBuffer = networkToStdoutBuffer[(newlineIndex + 1)...]

                    trackInboundResponse(in: Data(messageData))

                    // Write complete message to stdout
                    var remainingDataToWrite = messageWithNewline
                    while !remainingDataToWrite.isEmpty {
                        let bytesWritten: Int = try remainingDataToWrite.withUnsafeBytes { buffer in
                            try stdout.write(UnsafeRawBufferPointer(buffer))
                        }

                        if bytesWritten < remainingDataToWrite.count {
                            await log.debug(
                                "Partial write: \(bytesWritten) of \(remainingDataToWrite.count) bytes"
                            )
                            // Remove the bytes that were written
                            remainingDataToWrite = remainingDataToWrite.dropFirst(bytesWritten)
                        } else {
                            // All bytes were written
                            remainingDataToWrite.removeAll()
                        }

                        // If we still have data to write, give a small delay to allow the system to process
                        if !remainingDataToWrite.isEmpty {
                            try await Task.sleep(for: .milliseconds(1))
                        }
                    }
                }
            } catch let error as NWError where error.errorCode == 96 {
                // Handle "No message available on STREAM" error
                await log.debug("Network read yielded no data, waiting...")
                consecutiveEmptyReads += 1
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                // Check if the connection was cancelled or closed
                if let nwError = error as? NWError,
                    nwError.errorCode == 57  // Socket is not connected
                        || nwError.errorCode == 54  // Connection reset by peer
                {
                    await log.debug("Connection closed by peer: \(error)")
                    throw StdioProxyError.connectionClosed
                }

                if error is StdioProxyError {
                    throw error
                }

                await log.error("Error in network handler: \(error)")
                throw error
            }
        }
    }
}

// Define custom errors for the StdioProxy
enum StdioProxyError: Swift.Error {
    case networkTimeout
    case connectionClosed
    case responseTimeout
}

// Create MCPService class to manage lifecycle
actor MCPService: Service {
    private var browser: NWBrowser?
    private var currentProxy: StdioProxy?

    func run() async throws {
        while true {
            do {
                await log.info("Starting Bonjour service discovery...")

                let browser = NWBrowser(
                    for: .bonjour(type: serviceType, domain: nil),
                    using: parameters
                )
                self.browser = browser

                // Find and connect to iMCP app with improved reliability
                let endpoint: NWEndpoint = try await withCheckedThrowingContinuation {
                    continuation in
                    let connectionState = ConnectionState()

                    // Set up a timeout task to ensure we don't wait forever
                    let timeoutTask = Task {
                        // Allow 30 seconds to find the service
                        try await Task.sleep(for: .seconds(30))

                        // If we haven't found a service by now, resume with an error
                        if await connectionState.checkAndSetResumed() {
                            await log.error("Bonjour service discovery timed out after 30 seconds")
                            continuation.resume(
                                throwing: MCPError.internalError("Service discovery timeout")
                            )
                        }
                    }

                    // Convert async handlers to sync handlers
                    browser.stateUpdateHandler = { state in
                        Task {
                            switch state {
                            case .failed(let error):
                                await log.error("Browser failed: \(error)")
                                if await connectionState.checkAndSetResumed() {
                                    timeoutTask.cancel()
                                    browser.cancel()
                                    continuation.resume(throwing: error)
                                }
                            case .ready:
                                await log.info("Browser is ready and searching for services")
                            case .waiting(let error):
                                await log.warning("Browser is waiting: \(error)")
                            default:
                                await log.debug("Browser state changed: \(state)")
                            }
                        }
                    }

                    browser.browseResultsChangedHandler = { results, changes in
                        Task {
                            await log.debug("Found \(results.count) Bonjour services")

                            // Log all discovered services for debugging
                            for (index, result) in results.enumerated() {
                                await log.debug("Service \(index + 1): \(result.endpoint)")
                            }

                            // If we have results, select the most appropriate one
                            if !results.isEmpty {
                                // First, try to find a service with "iMCP" in the endpoint description
                                let imcpServices = results.filter {
                                    String(describing: $0.endpoint).contains("iMCP")
                                }

                                let selectedService: NWBrowser.Result

                                if !imcpServices.isEmpty {
                                    // Prefer services with iMCP in the description
                                    selectedService = imcpServices.first!
                                    await log.info(
                                        "Selected iMCP service: \(selectedService.endpoint)"
                                    )
                                } else {
                                    // Fall back to the first available service
                                    selectedService = results.first!
                                    await log.info(
                                        "No specific iMCP service found, using: \(selectedService.endpoint)"
                                    )
                                }

                                if await connectionState.checkAndSetResumed() {
                                    timeoutTask.cancel()
                                    browser.cancel()
                                    await log.info("Selected endpoint: \(selectedService.endpoint)")
                                    continuation.resume(returning: selectedService.endpoint)
                                }
                            }
                        }
                    }

                    Task {
                        await log.info("Starting Bonjour browser to discover MCP services...")
                    }
                    browser.start(queue: .main)
                }

                await log.info("Creating connection to endpoint...")

                // Create the proxy
                let proxy = StdioProxy(
                    endpoint: endpoint,
                    parameters: parameters,
                    stdinBufferSize: 10 * 1024 * 1024,  // 10MB for large responses
                    networkBufferSize: 10 * 1024 * 1024  // 10MB for large responses
                )
                self.currentProxy = proxy

                do {
                    try await proxy.start()
                } catch let error as StdioProxyError {
                    switch error {
                    // Removed stdinTimeout case as it's no longer thrown
                    // case .stdinTimeout:
                    //     await log.info("Stdin timed out, will reconnect...")
                    //     try await Task.sleep(for: .seconds(1))
                    //     continue
                    case .networkTimeout:
                        await log.info("Network timed out, will reconnect...")
                        try await Task.sleep(for: .seconds(1))
                        continue
                    case .connectionClosed:
                        await log.critical("Connection closed, terminating...")
                        return
                    case .responseTimeout:
                        // Exit so the MCP client fails the pending call immediately and
                        // respawns a fresh proxy, instead of letting it hang on a dead link.
                        await log.critical("Request unanswered, terminating...")
                        return
                    }
                } catch let error as NWError where error.errorCode == 54 || error.errorCode == 57 {
                    // Handle connection reset by peer (54) or socket not connected (57)
                    await log.critical("Network connection terminated: \(error), shutting down...")
                    return
                } catch {
                    // Rethrow other errors to be handled by the outer catch block
                    throw error
                }
            } catch {
                // Handle all other errors with retry
                await log.error("Connection error: \(error)")
                await log.info("Will retry connection in 5 seconds...")
                try await Task.sleep(for: .seconds(5))
            }
        }
    }

    func shutdown() async throws {
        browser?.cancel()
        if let proxy = currentProxy {
            await proxy.stop()
        }
    }
}

// Update the ServiceLifecycle initialization
let lifecycle = ServiceGroup(
    configuration: .init(
        services: [.init(service: MCPService(), successTerminationBehavior: .gracefullyShutdownGroup)],
        logger: log
    )
)

try await lifecycle.run()
