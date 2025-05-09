const std = @import("std");

/// HTTP Server implementation
/// Server metrics struct for tracking statistics
pub const ServerMetrics = struct {
    // Import atomic ordering constants for easier reference
    const Ordering = std.builtin.AtomicOrder;

    // Total connections since server start
    total_connections: std.atomic.Value(u64),
    // Total requests processed successfully
    total_requests: std.atomic.Value(u64),
    // Failed requests (e.g., parse errors, handler errors)
    failed_requests: std.atomic.Value(u64),
    // Connections rejected due to connection limit
    rejected_connections: std.atomic.Value(u64),
    // Total bytes received
    bytes_received: std.atomic.Value(u64),
    // Total bytes sent
    bytes_sent: std.atomic.Value(u64),
    // Timeouts that occurred
    timeouts: std.atomic.Value(u64),
    // Server start time for uptime calculation
    start_time: i64,

    /// Initialize server metrics with zero values
    pub fn init() ServerMetrics {
        return ServerMetrics{
            .total_connections = std.atomic.Value(u64).init(0),
            .total_requests = std.atomic.Value(u64).init(0),
            .failed_requests = std.atomic.Value(u64).init(0),
            .rejected_connections = std.atomic.Value(u64).init(0),
            .bytes_received = std.atomic.Value(u64).init(0),
            .bytes_sent = std.atomic.Value(u64).init(0),
            .timeouts = std.atomic.Value(u64).init(0),
            .start_time = std.time.milliTimestamp(),
        };
    }

    /// Get server uptime in milliseconds
    pub fn getUptime(self: *ServerMetrics) i64 {
        const now = std.time.milliTimestamp();
        return now - self.start_time;
    }

    /// Report server metrics as a formatted string
    pub fn report(self: *ServerMetrics, allocator: std.mem.Allocator) ![]const u8 {
        const uptime_ms = self.getUptime();
        const uptime_s = @as(f64, @floatFromInt(uptime_ms)) / 1000.0;

        return try std.fmt.allocPrint(allocator,
            \\Server Metrics:
            \\  Uptime: {d:.2} seconds
            \\  Total Connections: {}
            \\  Current Active Connections: {}
            \\  Total Requests: {}
            \\  Failed Requests: {}
            \\  Rejected Connections: {}
            \\  Timeouts: {}
            \\  Data Received: {} bytes
            \\  Data Sent: {} bytes
            \\
        , .{
            uptime_s,
            self.total_connections.load(Ordering.monotonic),
            self.total_connections.load(Ordering.monotonic) - self.total_requests.load(Ordering.monotonic),
            self.total_requests.load(Ordering.monotonic),
            self.failed_requests.load(Ordering.monotonic),
            self.rejected_connections.load(Ordering.monotonic),
            self.timeouts.load(Ordering.monotonic),
            self.bytes_received.load(Ordering.monotonic),
            self.bytes_sent.load(Ordering.monotonic),
        });
    }
};

pub const HttpServer = struct {
    // Import atomic ordering constants for easier reference
    const Ordering = std.builtin.AtomicOrder;

    // Define ListenContext struct here so it's accessible throughout HttpServer
    const ListenContext = struct {
        server: *HttpServer,
        handler: *const fn (*Connection) anyerror!void,
    };

    allocator: std.mem.Allocator,
    address: std.net.Address,
    server: std.net.Server,
    thread_pool: ?*ThreadPool,
    max_connections: usize,
    num_threads: usize,
    connection_timeout_ms: u32,
    // Graceful shutdown controls
    shutdown_requested: std.atomic.Value(bool),
    listen_thread: ?std.Thread,
    listen_context: ?*ListenContext, // Store the listen context for proper cleanup
    backlog_size: u32,
    // Server metrics
    metrics: ServerMetrics,
    // Use a simpler approach - just reuse the existing server instance
    // but set this flag to prevent more accept() calls
    server_closed: bool = false,

    /// Initialize a new HTTP server
    /// - host: The hostname to listen on
    /// - port: The port to listen on
    /// - num_threads: Number of worker threads (defaults to number of CPU cores)
    /// - max_connections: Maximum number of concurrent connections (defaults to 100)
    /// - connection_timeout_ms: Timeout for individual connections in milliseconds (defaults to 30000, 0 = no timeout)
    /// - backlog_size: TCP connection backlog size (defaults to 128)
    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16, num_threads: ?usize, max_connections: ?usize, connection_timeout_ms: ?u32, backlog_size: ?u32) !HttpServer {
        const address = try std.net.Address.resolveIp(host, port);
        // Note: backlog_size is currently ignored as the Zig std lib in this version
        // doesn't support setting the backlog size directly. It will use the default.
        const server = try address.listen(.{
            .reuse_address = true,
        });

        // Default to number of logical CPU cores if thread count not specified
        const actual_num_threads = num_threads orelse @max(1, std.Thread.getCpuCount() catch 4);

        // Default to 100 max connections if not specified
        const actual_max_connections = max_connections orelse 100;

        // Default to 30 seconds timeout if not specified
        const actual_timeout_ms = connection_timeout_ms orelse 30000;

        return HttpServer{
            .allocator = allocator,
            .address = address,
            .server = server,
            .thread_pool = null,
            .max_connections = actual_max_connections,
            .num_threads = actual_num_threads,
            .connection_timeout_ms = actual_timeout_ms,
            .shutdown_requested = std.atomic.Value(bool).init(false),
            .listen_thread = null,
            .listen_context = null,
            .backlog_size = backlog_size orelse 128,
            .metrics = ServerMetrics.init(),
        };
    }

    pub fn deinit(self: *HttpServer) void {
        std.debug.print("HttpServer.deinit() called\n", .{});

        // Signal graceful shutdown
        self.shutdown();
        std.debug.print("Graceful shutdown initiated\n", .{});

        // Wait for listen thread to complete if it was started
        if (self.listen_thread) |thread| {
            std.debug.print("Waiting for listen thread to complete\n", .{});
            thread.join();
            std.debug.print("Listen thread completed\n", .{});
        }

        // Clean up listen context
        if (self.listen_context) |listen_ctx| {
            std.debug.print("Freeing listen context at {*}\n", .{listen_ctx});
            self.allocator.destroy(listen_ctx);
            self.listen_context = null;
        } else {
            std.debug.print("No listen context to free\n", .{});
        }

        // Clean up thread pool
        if (self.thread_pool) |thread_pool| {
            std.debug.print("Cleaning up thread pool at {*}\n", .{thread_pool});
            // Free thread_pool memory - this will call ThreadPool.deinit() method
            thread_pool.deinit();
            // thread_pool instance was heap-allocated in startListening, so we need to free it
            self.allocator.destroy(thread_pool);
            self.thread_pool = null;
        } else {
            std.debug.print("No thread pool to clean up\n", .{});
        }

        // Now it's safe to fully close the server
        if (!self.server_closed) {
            std.debug.print("Closing server socket\n", .{});
            self.server.deinit();
        } else {
            std.debug.print("Server socket was already marked as closed\n", .{});
        }
        std.debug.print("HttpServer.deinit() complete\n", .{});
    }

    /// Request a graceful shutdown of the server
    /// This will stop accepting new connections but let existing ones complete
    pub fn shutdown(self: *HttpServer) void {
        std.debug.print("HttpServer.shutdown() called\n", .{});

        // Set shutdown flag
        self.shutdown_requested.store(true, Ordering.monotonic);

        // Mark server as closed but don't actually close it to avoid the unreachable panic
        self.server_closed = true;
        std.debug.print("Server marked as closed\n", .{});

        // If we have a thread pool, wake it up for quicker shutdown
        if (self.thread_pool) |thread_pool| {
            // Signal all threads to shut down
            thread_pool.shutdown.store(true, Ordering.monotonic);

            // Wake up all worker threads
            for (0..thread_pool.threads.len) |_| {
                thread_pool.jobs.signal.post();
            }
            std.debug.print("Worker threads signaled to shut down\n", .{});
        }

        std.debug.print("HttpServer.shutdown() complete\n", .{});
    }

    /// Set the maximum number of concurrent connections
    pub fn setMaxConnections(self: *HttpServer, max_connections: usize) void {
        self.max_connections = max_connections;
        if (self.thread_pool) |thread_pool| {
            thread_pool.setMaxConnections(max_connections);
        }
    }

    /// Get the current number of active connections
    pub fn getCurrentConnections(self: *HttpServer) usize {
        if (self.thread_pool) |thread_pool| {
            return thread_pool.getCurrentConnections();
        }
        return 0;
    }

    /// Set the connection timeout in milliseconds
    /// A value of 0 means no timeout.
    pub fn setConnectionTimeout(self: *HttpServer, timeout_ms: u32) void {
        self.connection_timeout_ms = timeout_ms;
    }

    /// Get server metrics
    pub fn getMetrics(self: *HttpServer) *ServerMetrics {
        return &self.metrics;
    }

    /// Get formatted server metrics report
    pub fn getMetricsReport(self: *HttpServer) ![]const u8 {
        return try self.metrics.report(self.allocator);
    }

    /// Start listening for incoming connections and handle them with the provided handler function
    /// Returns immediately after starting the listener thread
    pub fn startListening(self: *HttpServer, handler: *const fn (*Connection) anyerror!void) !void {
        // Initialize the thread pool if not already done
        if (self.thread_pool == null) {
            self.thread_pool = try ThreadPool.init(self.allocator, self.num_threads, self.max_connections);
        }

        // Create listen context for the thread
        const listen_ctx = try self.allocator.create(ListenContext);
        errdefer self.allocator.destroy(listen_ctx);

        listen_ctx.* = .{
            .server = self,
            .handler = handler,
        };

        // Store the context for cleanup in deinit
        self.listen_context = listen_ctx;

        // Start a dedicated thread for accepting connections
        self.listen_thread = try std.Thread.spawn(.{}, struct {
            fn run(ctx: *ListenContext) void {
                // Debug output to verify context is being used
                std.debug.print("Listen thread started with context at {*}\n", .{ctx});

                listenThread(ctx.server, ctx.handler) catch |err| {
                    if (err != error.ShutdownRequested) {
                        std.debug.print("Listen thread error: {}\n", .{err});
                    }
                };
                // Note: we don't destroy ctx here anymore - it's handled in HttpServer.deinit
                std.debug.print("Listen thread exiting\n", .{});
            }
        }.run, .{listen_ctx});

        std.debug.print("HTTP server listening on {}, max connections: {}, thread count: {}, backlog: {}\n", .{ self.address, self.max_connections, self.num_threads, self.backlog_size });
        std.debug.print("Stored listen context at {*}\n", .{self.listen_context.?});
    }

    /// Run the listening loop in a separate thread
    /// This allows for graceful shutdown when needed
    fn listenThread(self: *HttpServer, handler: *const fn (*Connection) anyerror!void) !void {
        const thread_pool = self.thread_pool.?;
        std.debug.print("Listen thread main loop starting\n", .{});

        while (!self.shutdown_requested.load(Ordering.monotonic) and !self.server_closed) {
            // Before trying to accept, check shutdown flags
            if (self.shutdown_requested.load(Ordering.monotonic) or self.server_closed) {
                std.debug.print("Shutdown detected at start of loop, exiting listen thread\n", .{});
                break;
            }

            // Use a simpler approach - just check the shutdown flag periodically
            // And sleep a short time to avoid tight loops
            std.time.sleep(100 * std.time.ns_per_ms);

            // Check if we should shut down
            if (self.shutdown_requested.load(Ordering.monotonic) or self.server_closed) {
                std.debug.print("Shutdown detected after sleep, exiting listen thread\n", .{});
                break;
            }

            // Accept a connection (should be non-blocking now)
            const conn = self.server.accept() catch |err| {
                std.debug.print("Error accepting connection: {}\n", .{err});

                // If shutdown was requested, break out of the loop gracefully
                if (self.shutdown_requested.load(Ordering.monotonic) or self.server_closed) {
                    std.debug.print("Shutdown detected during accept error, exiting listen thread\n", .{});
                    break;
                }

                // Add a small sleep to prevent tight loop in case of persistent errors
                std.time.sleep(10 * std.time.ns_per_ms);
                continue;
            };

            // Check shutdown flag again after potentially long accept call
            if (self.shutdown_requested.load(Ordering.monotonic) or self.server_closed) {
                std.debug.print("Shutdown detected after accept, closing connection\n", .{});
                // Close the socket safely without trying to use the connection struct
                // This avoids any double-close issues during shutdown
                conn.stream.close();
                break;
            }

            // Update total connections metric
            _ = self.metrics.total_connections.fetchAdd(1, Ordering.monotonic);

            // If at connection limit, reject the connection
            if (thread_pool.getCurrentConnections() >= self.max_connections) {
                std.debug.print("Connection limit reached, rejecting connection from {}\n", .{conn.address});
                _ = self.metrics.rejected_connections.fetchAdd(1, Ordering.monotonic);
                conn.stream.close();
                continue;
            }

            // Allocate a new Connection on the heap so it persists after this function
            var connection_ptr = self.allocator.create(Connection) catch |err| {
                std.debug.print("Error allocating connection: {}\n", .{err});
                conn.stream.close();
                continue;
            };

            connection_ptr.* = Connection{
                .allocator = self.allocator,
                .stream = conn.stream,
                .address = conn.address,
                .timeout_ms = self.connection_timeout_ms,
                .created_at = std.time.milliTimestamp(),
                .server_metrics = &self.metrics,
                .is_closed = false, // Explicitly mark as not closed
            };

            // Create a job for the connection
            var job = self.allocator.create(ConnectionJob) catch |err| {
                std.debug.print("Error creating job: {}\n", .{err});
                connection_ptr.deinit();
                self.allocator.destroy(connection_ptr);
                continue;
            };

            job.* = ConnectionJob.init(connection_ptr, handler);

            // Submit the job to the thread pool
            thread_pool.submit(&job.job) catch |err| {
                std.debug.print("Error submitting job: {}\n", .{err});
                connection_ptr.deinit();
                self.allocator.destroy(connection_ptr);
                self.allocator.destroy(job);
                continue;
            };
        }

        // If we get here, shutdown was requested
        return error.ShutdownRequested;
    }

    /// Listen for incoming connections and handle them with the provided handler function
    /// This is a blocking call that runs until a shutdown is requested
    pub fn listen(self: *HttpServer, handler: *const fn (*Connection) anyerror!void) !void {
        // Initialize the thread pool if not already done
        if (self.thread_pool == null) {
            self.thread_pool = try ThreadPool.init(self.allocator, self.num_threads, self.max_connections);
        }

        const thread_pool = self.thread_pool.?;

        std.debug.print("HTTP server listening on {}, max connections: {}, thread count: {}, backlog: {}\n", .{ self.address, self.max_connections, self.num_threads, self.backlog_size });

        // Note: In this version of Zig, we can't set non-blocking mode directly
        // We'll handle timeouts in a different way

        while (!self.shutdown_requested.load(Ordering.monotonic)) {
            // Accept a connection (blocking call)
            const conn = self.server.accept() catch |err| {
                std.debug.print("Error accepting connection: {}\n", .{err});
                // Add a small sleep to prevent tight loop in case of persistent errors
                std.time.sleep(10 * std.time.ns_per_ms);
                continue;
            };

            // Periodically check the shutdown flag
            if (self.shutdown_requested.load(Ordering.monotonic)) {
                conn.stream.close();
                break;
            }

            // Allocate a new Connection on the heap so it persists after this function
            var connection_ptr = self.allocator.create(Connection) catch |err| {
                std.debug.print("Error allocating connection: {}\n", .{err});
                conn.stream.close();
                continue;
            };

            connection_ptr.* = Connection{
                .allocator = self.allocator,
                .stream = conn.stream,
                .address = conn.address,
                .timeout_ms = self.connection_timeout_ms,
                .created_at = std.time.milliTimestamp(),
                .server_metrics = &self.metrics,
                .is_closed = false, // Explicitly mark as not closed
            };

            // Create a job for the connection
            var job = self.allocator.create(ConnectionJob) catch |err| {
                std.debug.print("Error creating job: {}\n", .{err});
                connection_ptr.deinit();
                self.allocator.destroy(connection_ptr);
                continue;
            };

            job.* = ConnectionJob.init(connection_ptr, handler);

            // Submit the job to the thread pool
            thread_pool.submit(&job.job) catch |err| {
                std.debug.print("Error submitting job: {}\n", .{err});
                connection_ptr.deinit();
                self.allocator.destroy(connection_ptr);
                self.allocator.destroy(job);
                continue;
            };
        }
    }
};

/// HTTP Connection
pub const Connection = struct {
    // Import atomic ordering constants for easier reference
    const Ordering = std.builtin.AtomicOrder;

    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    address: std.net.Address,
    /// Connection timeout in milliseconds. If 0, no timeout is applied.
    timeout_ms: u32,
    /// Timestamp when the connection was created
    created_at: i64,
    /// Reference to server metrics for tracking
    server_metrics: ?*ServerMetrics = null,
    /// Whether this connection has already been closed
    is_closed: bool = false,

    pub fn deinit(self: *Connection) void {
        // When connection is closed, update metrics for completed request
        if (self.server_metrics) |metrics| {
            _ = metrics.total_requests.fetchAdd(1, Ordering.monotonic);
        }

        // Only close the stream if it hasn't been closed already
        if (!self.is_closed) {
            self.stream.close();
            self.is_closed = true;
        }
    }

    /// Returns whether the connection has timed out
    pub fn hasTimedOut(self: *Connection) bool {
        if (self.timeout_ms == 0) return false;

        const now = std.time.milliTimestamp();
        const elapsed = now - self.created_at;
        const is_timed_out = elapsed > self.timeout_ms;

        // Record timeout in metrics if it occurred
        if (is_timed_out) {
            if (self.server_metrics) |metrics| {
                _ = metrics.timeouts.fetchAdd(1, Ordering.monotonic);
            }
        }

        return is_timed_out;
    }

    pub fn read(self: *Connection, buffer: []u8) !usize {
        // Check if connection has timed out
        if (self.hasTimedOut()) {
            return error.ConnectionTimedOut;
        }

        // Check if connection is already closed
        if (self.is_closed) {
            return error.ConnectionClosed;
        }

        // For simplicity, we're relying on the global timeout mechanism
        // The OS will typically have its own timeout mechanisms for inactive connections
        const bytes_read = self.stream.read(buffer) catch |err| {
            // If we get a broken pipe or connection reset, mark as closed
            switch (err) {
                error.BrokenPipe, error.ConnectionResetByPeer => {
                    self.is_closed = true;
                    return err;
                },
                else => return err,
            }
        };

        // Record bytes received in metrics
        if (self.server_metrics) |metrics| {
            _ = metrics.bytes_received.fetchAdd(bytes_read, Ordering.monotonic);
        }

        return bytes_read;
    }

    pub fn write(self: *Connection, buffer: []const u8) !usize {
        // Check if connection has timed out
        if (self.hasTimedOut()) {
            return error.ConnectionTimedOut;
        }

        // Check if connection is already closed
        if (self.is_closed) {
            return error.ConnectionClosed;
        }

        // For simplicity, we're relying on the global timeout mechanism
        // The OS will typically have its own timeout mechanisms for inactive connections
        const bytes_written = self.stream.write(buffer) catch |err| {
            // If we get a broken pipe or connection reset, mark as closed
            switch (err) {
                error.BrokenPipe, error.ConnectionResetByPeer => {
                    self.is_closed = true;
                    return err;
                },
                else => return err,
            }
        };

        // Record bytes sent in metrics
        if (self.server_metrics) |metrics| {
            _ = metrics.bytes_sent.fetchAdd(bytes_written, Ordering.monotonic);
        }

        return bytes_written;
    }

    pub fn writeAll(self: *Connection, buffer: []const u8) !void {
        // Check if connection has timed out
        if (self.hasTimedOut()) {
            return error.ConnectionTimedOut;
        }

        // Check if connection is already closed
        if (self.is_closed) {
            return error.ConnectionClosed;
        }

        var remaining = buffer;
        while (remaining.len > 0) {
            const bytes_written = try self.write(remaining);
            remaining = remaining[bytes_written..];
        }
    }

    /// Track a failed request in metrics
    pub fn recordFailedRequest(self: *Connection) void {
        if (self.server_metrics) |metrics| {
            _ = metrics.failed_requests.fetchAdd(1, Ordering.monotonic);
        }
    }

    /// Send an HTTP response
    pub fn sendResponse(self: *Connection, status_code: u16, content_type: []const u8, body: []const u8) !void {
        // Use stack-allocated buffer for static strings where possible
        const status_message = switch (status_code) {
            200 => "OK",
            400 => "Bad Request",
            404 => "Not Found",
            500 => "Internal Server Error",
            else => "Unknown",
        };

        // Build status line
        var status_line_buf: [128]u8 = undefined;
        const status_line = try std.fmt.bufPrint(&status_line_buf, "HTTP/1.1 {d} {s}\r\n", .{ status_code, status_message });
        try self.writeAll(status_line);

        // Content-Type header
        try self.writeAll("Content-Type: ");
        try self.writeAll(content_type);
        try self.writeAll("\r\n");

        // Content-Length header
        var content_length_buf: [64]u8 = undefined;
        const content_length = try std.fmt.bufPrint(&content_length_buf, "Content-Length: {d}\r\n", .{body.len});
        try self.writeAll(content_length);

        // Connection header and end of headers
        try self.writeAll("Connection: close\r\n\r\n");

        // Body
        try self.writeAll(body);
    }

    /// Parse HTTP request
    pub fn parseRequest(self: *Connection) !HttpRequest {
        // Use stack buffer for the HTTP request
        var buffer: [8192]u8 = undefined;
        const bytes_read = try self.read(&buffer);
        if (bytes_read == 0) {
            return error.ConnectionClosed;
        }

        const data = buffer[0..bytes_read];

        // Find the end of the request line
        const request_line_end = std.mem.indexOf(u8, data, "\r\n") orelse {
            return error.InvalidRequest;
        };

        const request_line = data[0..request_line_end];

        // Split the request line into method, path, and version
        var request_line_iter = std.mem.splitScalar(u8, request_line, ' ');
        const method = request_line_iter.next() orelse {
            return error.InvalidRequest;
        };
        const path = request_line_iter.next() orelse {
            return error.InvalidRequest;
        };
        const version = request_line_iter.next() orelse {
            return error.InvalidRequest;
        };

        // Find the end of the headers
        const headers_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse {
            return error.InvalidRequest;
        };

        const body_start = headers_end + 4;
        const body = if (body_start < bytes_read) data[body_start..] else "";

        return HttpRequest{
            .method = try self.allocator.dupe(u8, method),
            .path = try self.allocator.dupe(u8, path),
            .version = try self.allocator.dupe(u8, version),
            .body = try self.allocator.dupe(u8, body),
            .allocator = self.allocator,
        };
    }
};

/// HTTP Request
pub const HttpRequest = struct {
    allocator: std.mem.Allocator,
    method: []const u8,
    path: []const u8,
    version: []const u8,
    body: []const u8,

    pub fn deinit(self: *HttpRequest) void {
        self.allocator.free(self.method);
        self.allocator.free(self.path);
        self.allocator.free(self.version);
        self.allocator.free(self.body);
    }
};

/// A thread pool for handling concurrent connections
pub const ThreadPool = struct {
    // Import atomic ordering constants for easier reference
    const Ordering = std.builtin.AtomicOrder;

    allocator: std.mem.Allocator,
    threads: []std.Thread,
    jobs: JobQueue,
    shutdown: std.atomic.Value(bool),

    // Connection tracking with mutex protection
    conn_mutex: std.Thread.Mutex,
    max_connections: usize,
    current_connections: usize,

    /// Initialize a new thread pool with the given number of threads
    pub fn init(allocator: std.mem.Allocator, thread_count: usize, max_connections: usize) !*ThreadPool {
        var self = try allocator.create(ThreadPool);
        errdefer allocator.destroy(self);

        self.* = ThreadPool{
            .allocator = allocator,
            .threads = try allocator.alloc(std.Thread, thread_count),
            .jobs = JobQueue.init(allocator),
            .shutdown = std.atomic.Value(bool).init(false),
            .conn_mutex = std.Thread.Mutex{},
            .max_connections = max_connections,
            .current_connections = 0,
        };
        errdefer self.allocator.free(self.threads);
        errdefer self.jobs.deinit();

        // Set the shutdown pointer in the JobQueue
        self.jobs.setShutdownPtr(&self.shutdown);

        // Spawn worker threads
        for (0..thread_count) |i| {
            self.threads[i] = try std.Thread.spawn(.{}, workerThread, .{self});
        }

        return self;
    }

    /// Clean up the thread pool
    pub fn deinit(self: *ThreadPool) void {
        std.debug.print("ThreadPool.deinit() called on pool at {*}\n", .{self});

        // Signal all threads to shut down
        self.shutdown.store(true, Ordering.monotonic);
        std.debug.print("ThreadPool shutdown flag set\n", .{});

        // Wake up all worker threads so they can see the shutdown flag
        // Post once for each thread
        for (0..self.threads.len) |i| {
            std.debug.print("Waking up worker thread {}\n", .{i});
            self.jobs.signal.post();
        }

        // Wait for all threads to finish
        for (self.threads) |thread| {
            thread.join();
        }
        std.debug.print("All worker threads joined\n", .{});

        // Clean up resources
        std.debug.print("Freeing {} thread handles\n", .{self.threads.len});
        self.allocator.free(self.threads);
        std.debug.print("Cleaning up job queue\n", .{});
        self.jobs.deinit();
        std.debug.print("ThreadPool resources cleaned up\n", .{});
        // Note: We don't destroy self here - this is now the caller's responsibility
        // since the caller (HttpServer.deinit) has to free the ThreadPool instance
    }

    /// Submit a job to the thread pool
    pub fn submit(self: *ThreadPool, job: *Job) !void {
        // If we're at max connections, wait until a connection finishes
        while (true) {
            // Lock the mutex to check and update connection count
            self.conn_mutex.lock();

            if (self.current_connections < self.max_connections) {
                // We have capacity, increment and proceed
                self.current_connections += 1;
                self.conn_mutex.unlock();
                break;
            }

            // No capacity, unlock and wait
            self.conn_mutex.unlock();
            std.time.sleep(std.time.ns_per_ms * 10);
        }

        try self.jobs.push(job);
    }

    /// Set the maximum number of concurrent connections
    pub fn setMaxConnections(self: *ThreadPool, max_connections: usize) void {
        self.conn_mutex.lock();
        defer self.conn_mutex.unlock();
        self.max_connections = max_connections;
    }

    /// Get the current number of active connections
    pub fn getCurrentConnections(self: *ThreadPool) usize {
        self.conn_mutex.lock();
        defer self.conn_mutex.unlock();
        return self.current_connections;
    }

    /// Worker thread function
    fn workerThread(self: *ThreadPool) void {
        while (!self.shutdown.load(Ordering.monotonic)) {
            // Wait for a job, handling any errors
            const job = self.jobs.pop() catch |err| {
                std.debug.print("Error popping job: {}\n", .{err});
                // Sleep a bit to avoid tight loop in case of persistent errors
                std.time.sleep(std.time.ns_per_ms * 10);
                continue;
            };

            if (job) |j| {
                // Execute the job with error handling
                j.execute() catch |err| {
                    std.debug.print("Error executing job: {}\n", .{err});
                };

                // Decrement the connection count when the job is done
                self.conn_mutex.lock();
                self.current_connections -= 1;
                self.conn_mutex.unlock();
            } else {
                // No job was available despite a signal
                // This could happen if another thread got the job first
                // or if we're shutting down
                std.time.sleep(std.time.ns_per_ms);
            }
        }
    }
};

/// A queue of jobs for the thread pool
const JobQueue = struct {
    // Import atomic ordering constants for easier reference
    const Ordering = std.builtin.AtomicOrder;

    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    jobs: std.ArrayList(*Job),
    signal: std.Thread.Semaphore,
    shutdown: *std.atomic.Value(bool),

    fn init(allocator: std.mem.Allocator) JobQueue {
        // Create a dummy shutdown atomic that's always false
        // This will be replaced with the ThreadPool's shutdown atomic when the ThreadPool is initialized
        const shutdown_ptr = allocator.create(std.atomic.Value(bool)) catch @panic("OOM");
        shutdown_ptr.* = std.atomic.Value(bool).init(false);

        return JobQueue{
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
            .jobs = std.ArrayList(*Job).init(allocator),
            .signal = std.Thread.Semaphore{},
            .shutdown = shutdown_ptr,
        };
    }

    fn setShutdownPtr(self: *JobQueue, shutdown: *std.atomic.Value(bool)) void {
        // Clean up the dummy shutdown atomic
        const old_ptr = self.shutdown;
        self.shutdown = shutdown;
        self.allocator.destroy(old_ptr);
    }

    fn deinit(self: *JobQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // If any jobs are left, log a warning
        if (self.jobs.items.len > 0) {
            std.debug.print("Warning: {} jobs still in queue during shutdown\n", .{self.jobs.items.len});
        }

        self.jobs.deinit();
    }

    fn push(self: *JobQueue, job: *Job) !void {
        // Don't accept new jobs if we're shutting down
        if (self.shutdown.load(Ordering.monotonic)) {
            return error.ShuttingDown;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.jobs.append(job);
        self.signal.post();
    }

    fn pop(self: *JobQueue) !?*Job {
        // If we're shutting down and there are no jobs, return null immediately
        if (self.shutdown.load(Ordering.monotonic)) {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.jobs.items.len == 0) {
                return null;
            }
        }

        // Wait for a job to be available or shutdown
        self.signal.wait();

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.jobs.items.len == 0) {
            return null;
        }

        return self.jobs.orderedRemove(0);
    }
};

/// A job for the thread pool
pub const Job = struct {
    execute_fn: *const fn (*Job) anyerror!void,

    pub fn execute(self: *Job) !void {
        return self.execute_fn(self);
    }
};

/// HTTP connection job for the thread pool
pub const ConnectionJob = struct {
    job: Job,
    connection: *Connection,
    handler: *const fn (*Connection) anyerror!void,
    allocator: std.mem.Allocator,

    pub fn init(connection: *Connection, handler: *const fn (*Connection) anyerror!void) ConnectionJob {
        return ConnectionJob{
            .job = Job{ .execute_fn = executeHandler },
            .connection = connection,
            .handler = handler,
            .allocator = connection.allocator,
        };
    }

    fn executeHandler(job_ptr: *Job) !void {
        // Get the containing ConnectionJob from its job field
        const offset = @offsetOf(ConnectionJob, "job");
        const ptr = @as([*]u8, @ptrCast(job_ptr)) - offset;
        const self = @as(*ConnectionJob, @ptrCast(@alignCast(ptr)));

        // Execute the handler - this will close the connection on error
        self.handler(self.connection) catch |err| {
            std.debug.print("Error in connection handler: {}\n", .{err});
        };

        // Cleanup - make sure we don't double-close
        if (!self.connection.is_closed) {
            self.connection.deinit();
        }
        self.allocator.destroy(self.connection);
        self.allocator.destroy(self);
    }
};
