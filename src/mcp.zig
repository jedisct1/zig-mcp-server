const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const builtin = @import("builtin");

// Only import net.zig when not targeting WebAssembly
const is_wasm = builtin.cpu.arch.isWasm();
const net = if (!is_wasm) @import("net.zig") else struct {};

/// MCP Protocol Constants
pub const PROTOCOL_VERSION = "0.4.0";

/// Tool handler function type
/// Now uses context instead of allocator for memory management
pub const ToolHandlerFn = *const fn (ctx: *jsonrpc.Context, params: std.json.Value) anyerror!std.json.Value;

/// MCP Tool definition
pub const Tool = struct {
    /// Tool name - stored in static memory
    name: []const u8,
    /// Tool description - stored in static memory
    description: []const u8,
    /// Tool handler function
    handler: ToolHandlerFn,
    /// Optional parameters schema (JSON Schema) - should be stored in static memory
    parameters: ?std.json.Value = null,
};

/// Transport type
pub const TransportType = if (is_wasm)
    enum {
        /// When compiling for WebAssembly, only stdio transport is available
        stdio,
    }
else
    enum {
        stdio,
        http,
    };

/// MCP Server settings
pub const Settings = if (is_wasm) struct {
    /// Transport type - only stdio available in WebAssembly
    transport: TransportType = .stdio,
    /// Array of tools - stored in static memory
    tools: []const Tool = &[_]Tool{},
} else struct {
    /// Transport type
    transport: TransportType = .stdio,
    /// Host for HTTP transport - stored in static memory
    host: []const u8 = "127.0.0.1",
    /// Port for HTTP transport
    port: u16 = 7777,
    /// Array of tools - stored in static memory
    tools: []const Tool = &[_]Tool{},
    /// Maximum number of concurrent connections (for HTTP transport)
    max_connections: ?usize = null,
    /// Number of worker threads (for HTTP transport)
    /// If null, will use the number of CPU cores
    thread_count: ?usize = null,
    /// Connection timeout in milliseconds (for HTTP transport)
    /// If 0, no timeout is applied
    connection_timeout_ms: u32 = 30000,
    /// TCP backlog size for the listening socket (for HTTP transport)
    backlog_size: ?u32 = null,
    /// Run HTTP server in non-blocking mode
    /// This starts a separate thread for accepting connections, allowing
    /// the main thread to continue execution.
    non_blocking_http: bool = false,
};

/// MCP Server state
pub const ServerState = enum {
    created,
    initializing,
    ready,
    error_state,
    shutdown,
};

/// MCP Server implementation
pub const Server = struct {
    /// Parent allocator for general allocations
    parent_allocator: std.mem.Allocator,
    /// Server settings
    settings: Settings,
    /// Current server state
    state: ServerState,
    /// Map of registered tools
    tools: std.StringHashMap(Tool),
    /// HTTP server (if using HTTP transport) - only available on non-WebAssembly targets
    http_server: if (!is_wasm) ?net.HttpServer else void,
    /// A context arena for the current request-response cycle
    request_context: jsonrpc.Context,

    pub fn init(allocator: std.mem.Allocator, settings: Settings) !Server {
        var tools = std.StringHashMap(Tool).init(allocator);

        // Register all tools
        for (settings.tools) |tool| {
            try tools.put(tool.name, tool);
        }

        if (is_wasm) {
            // WebAssembly version - no HTTP support
            return Server{
                .parent_allocator = allocator,
                .settings = settings,
                .state = .created,
                .tools = tools,
                .http_server = {}, // void value for WebAssembly
                .request_context = jsonrpc.Context.init(allocator),
            };
        } else {
            // Native version with HTTP support
            return Server{
                .parent_allocator = allocator,
                .settings = settings,
                .state = .created,
                .tools = tools,
                .http_server = null,
                .request_context = jsonrpc.Context.init(allocator),
            };
        }
    }

    /// Explicitly request server shutdown
    /// This will initiate a graceful shutdown process
    pub fn shutdown(self: *Server) void {
        if (!is_wasm) {
            // Only try to shutdown HTTP server on non-WebAssembly platforms
            if (self.http_server) |*http_server| {
                http_server.shutdown();
            }
        }
        self.state = .shutdown;
    }

    pub fn deinit(self: *Server) void {
        // Ensure server is shut down before cleanup
        if (self.state != .shutdown) {
            self.shutdown();
        }

        // Cleanup server resources
        if (!is_wasm) {
            // Only try to deinit HTTP server on non-WebAssembly platforms
            if (self.http_server) |*http_server| {
                http_server.deinit();
            }
        }

        self.tools.deinit();
        self.request_context.deinit();
    }

    pub fn start(self: *Server) !void {
        if (is_wasm) {
            // In WebAssembly, we only support stdio transport
            try self.startStdioTransport();
        } else {
            // On other platforms, both transports are available
            switch (self.settings.transport) {
                .stdio => try self.startStdioTransport(),
                .http => try self.startHttpTransport(),
            }
        }
    }

    fn startStdioTransport(self: *Server) !void {
        const stdin = std.io.getStdIn().reader();
        const stdout = std.io.getStdOut().writer();

        self.state = .ready;

        while (self.state != .shutdown) {
            var buffer: [4096]u8 = undefined;
            const bytes_read = try stdin.read(&buffer);
            if (bytes_read == 0) {
                // EOF, exit
                break;
            }

            const message = buffer[0..bytes_read];
            const response = try self.handleRequest(message);
            if (response.len > 0) {
                try stdout.writeAll(response);
                try stdout.writeAll("\n");
            }

            // Reset the request context for the next iteration
            self.request_context.reset();
        }
    }

    fn startHttpTransport(self: *Server) !void {
        // HTTP transport is not available in WebAssembly
        if (is_wasm) {
            return error.HttpTransportNotAvailableInWebAssembly;
        } else {
            // Initialize the HTTP server with thread pool and connection limiting
            var http_server = try net.HttpServer.init(self.parent_allocator, self.settings.host, self.settings.port, self.settings.thread_count, // Use the configured thread count or detect CPU cores
                self.settings.max_connections, // Use the configured max connections or default
                self.settings.connection_timeout_ms, // Connection timeout in milliseconds
                self.settings.backlog_size // TCP backlog size
            );
            self.http_server = http_server;
            self.state = .ready;

            // Store server instance for the HTTP handler
            g_server = self;

            // Start the HTTP server in non-blocking mode if specified
            if (self.settings.non_blocking_http) {
                try http_server.startListening(handleHttpConnection);
            } else {
                try http_server.listen(handleHttpConnection);
            }
        }
    }

    // HTTP connection handler functions are only available on non-WebAssembly platforms
    fn handleHttpConnection(conn: *net.Connection) !void {
        if (is_wasm) {
            return error.HttpHandlerNotAvailableInWebAssembly;
        } else {
            defer conn.deinit();

            var request = try conn.parseRequest();
            defer request.deinit();

            // Health check endpoint
            if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/health")) {
                // Simple static health response
                const health_response = "{\"status\":\"healthy\",\"server\":\"zig-mcp\"}";
                try conn.sendResponse(200, "application/json", health_response);
                return;
            }

            // Only handle POST requests to /jsonrpc for API
            if (!std.mem.eql(u8, request.method, "POST") or !std.mem.eql(u8, request.path, "/jsonrpc")) {
                try conn.sendResponse(404, "text/plain", "Not Found");
                return;
            }

            // Get server instance from the global pointer
            const server = g_server;

            // Process the JSON-RPC request
            const response = try server.handleRequest(request.body);

            // Send the response
            try conn.sendResponse(200, "application/json", response);

            // Reset the request context for the next request
            server.request_context.reset();
        }
    }

    // Global server pointer for the HTTP handler - only used in non-WebAssembly platforms
    var g_server: if (!is_wasm) *Server else void = if (!is_wasm) undefined else {};

    pub fn handleRequest(self: *Server, request_str: []const u8) ![]const u8 {
        // Parse the JSON-RPC request
        const request = jsonrpc.parseMessage(&self.request_context, request_str) catch |err| {
            std.debug.print("Error parsing request: {}\n", .{err});
            const error_response = try jsonrpc.createErrorResponse(&self.request_context, std.json.Value{ .null = {} }, .parseError, "Parse error");
            return try jsonrpc.stringifyValue(self.request_context.allocator(), error_response);
        };

        // Validate the JSON-RPC request
        jsonrpc.validateMessage(request) catch |err| {
            std.debug.print("Invalid request: {}\n", .{err});
            const error_response = try jsonrpc.createErrorResponse(&self.request_context, request.object.get("id") orelse std.json.Value{ .null = {} }, .invalidRequest, "Invalid Request");
            return try jsonrpc.stringifyValue(self.request_context.allocator(), error_response);
        };

        // Extract method and params
        const method = request.object.get("method") orelse {
            const error_response = try jsonrpc.createErrorResponse(&self.request_context, request.object.get("id") orelse std.json.Value{ .null = {} }, .invalidRequest, "Method not specified");
            return try jsonrpc.stringifyValue(self.request_context.allocator(), error_response);
        };

        if (method != .string) {
            const error_response = try jsonrpc.createErrorResponse(&self.request_context, request.object.get("id") orelse std.json.Value{ .null = {} }, .invalidRequest, "Method must be a string");
            return try jsonrpc.stringifyValue(self.request_context.allocator(), error_response);
        }

        const params = request.object.get("params") orelse std.json.Value{ .object = std.json.ObjectMap.init(self.request_context.allocator()) };

        // Check if this is an initialization request
        if (std.mem.eql(u8, method.string, "initialize")) {
            return try self.handleInitialize(request);
        }

        // Check if server is initialized
        if (self.state != .ready) {
            const error_response = try jsonrpc.createErrorResponse(&self.request_context, request.object.get("id") orelse std.json.Value{ .null = {} }, .serverNotInitialized, "Server not initialized");
            return try jsonrpc.stringifyValue(self.request_context.allocator(), error_response);
        }

        // Handle initialized notification
        if (std.mem.eql(u8, method.string, "initialized")) {
            // Just acknowledge, no response needed for notifications
            return &[_]u8{};
        }

        // Handle shutdown request
        if (std.mem.eql(u8, method.string, "shutdown")) {
            self.state = .shutdown;
            const response = try jsonrpc.createSuccessResponse(&self.request_context, request.object.get("id") orelse std.json.Value{ .null = {} }, std.json.Value{ .null = {} });
            return try jsonrpc.stringifyValue(self.request_context.allocator(), response);
        }

        // Parse mcp/tools/invoke methods
        if (std.mem.startsWith(u8, method.string, "mcp/tools/")) {
            const tool_method = method.string["mcp/tools/".len..];

            if (std.mem.eql(u8, tool_method, "list")) {
                return try self.handleToolsList(request);
            } else if (std.mem.eql(u8, tool_method, "invoke")) {
                return try self.handleToolInvoke(request, params);
            }
        }

        // Method not found
        const error_response = try jsonrpc.createErrorResponse(&self.request_context, request.object.get("id") orelse std.json.Value{ .null = {} }, .methodNotFound, "Method not found");
        return try jsonrpc.stringifyValue(self.request_context.allocator(), error_response);
    }

    fn handleInitialize(self: *Server, request: std.json.Value) ![]const u8 {
        self.state = .initializing;

        // Extract client capabilities from params
        const params = request.object.get("params") orelse {
            const error_response = try jsonrpc.createErrorResponse(&self.request_context, request.object.get("id") orelse std.json.Value{ .null = {} }, .invalidParams, "Params missing in initialize request");
            return try jsonrpc.stringifyValue(self.request_context.allocator(), error_response);
        };

        // Check protocol version (optional)
        if (params.object.get("protocolVersion")) |version| {
            if (version != .string or !std.mem.eql(u8, version.string, PROTOCOL_VERSION)) {
                const error_response = try jsonrpc.createErrorResponse(&self.request_context, request.object.get("id") orelse std.json.Value{ .null = {} }, .unknownProtocolVersion, "Unsupported protocol version");
                return try jsonrpc.stringifyValue(self.request_context.allocator(), error_response);
            }
        }

        // Create server capabilities
        var capabilities = std.json.Value{ .object = std.json.ObjectMap.init(self.request_context.allocator()) };
        try capabilities.object.put("protocolVersion", std.json.Value{ .string = try self.request_context.allocator().dupe(u8, PROTOCOL_VERSION) });

        // Add tools capability
        var tools_capability = std.json.Value{ .object = std.json.ObjectMap.init(self.request_context.allocator()) };
        try tools_capability.object.put("enabled", std.json.Value{ .bool = true });
        try capabilities.object.put("tools", tools_capability);

        // Create response
        var result = std.json.Value{ .object = std.json.ObjectMap.init(self.request_context.allocator()) };
        try result.object.put("capabilities", capabilities);
        try result.object.put("serverInfo", try createServerInfo(&self.request_context));

        const response = try jsonrpc.createSuccessResponse(&self.request_context, request.object.get("id") orelse std.json.Value{ .null = {} }, result);

        self.state = .ready;
        return try jsonrpc.stringifyValue(self.request_context.allocator(), response);
    }

    fn handleToolsList(self: *Server, request: std.json.Value) ![]const u8 {
        var tools_array = std.json.Value{ .array = std.json.Array.init(self.request_context.allocator()) };

        var tools_iter = self.tools.iterator();
        while (tools_iter.next()) |tool_entry| {
            const tool = tool_entry.value_ptr.*;
            var tool_obj = std.json.Value{ .object = std.json.ObjectMap.init(self.request_context.allocator()) };

            try tool_obj.object.put("name", std.json.Value{ .string = try self.request_context.allocator().dupe(u8, tool.name) });
            try tool_obj.object.put("description", std.json.Value{ .string = try self.request_context.allocator().dupe(u8, tool.description) });

            if (tool.parameters) |params| {
                // If parameters schema is provided, we need to clone it
                // into our arena allocator since it's in static memory
                const cloned = try cloneJsonValue(self.request_context.allocator(), params);
                try tool_obj.object.put("parameters", cloned);
            }

            try tools_array.array.append(tool_obj);
        }

        var result = std.json.Value{ .object = std.json.ObjectMap.init(self.request_context.allocator()) };
        try result.object.put("tools", tools_array);

        const response = try jsonrpc.createSuccessResponse(&self.request_context, request.object.get("id") orelse std.json.Value{ .null = {} }, result);

        return try jsonrpc.stringifyValue(self.request_context.allocator(), response);
    }

    fn handleToolInvoke(self: *Server, request: std.json.Value, params: std.json.Value) ![]const u8 {
        if (params != .object) {
            const error_response = try jsonrpc.createErrorResponse(&self.request_context, request.object.get("id") orelse std.json.Value{ .null = {} }, .invalidParams, "Params must be an object");
            return try jsonrpc.stringifyValue(self.request_context.allocator(), error_response);
        }

        // Extract tool name and params
        const name_value = params.object.get("name") orelse {
            const error_response = try jsonrpc.createErrorResponse(&self.request_context, request.object.get("id") orelse std.json.Value{ .null = {} }, .invalidParams, "Tool name missing");
            return try jsonrpc.stringifyValue(self.request_context.allocator(), error_response);
        };

        if (name_value != .string) {
            const error_response = try jsonrpc.createErrorResponse(&self.request_context, request.object.get("id") orelse std.json.Value{ .null = {} }, .invalidParams, "Tool name must be a string");
            return try jsonrpc.stringifyValue(self.request_context.allocator(), error_response);
        }

        const tool_params = params.object.get("params") orelse std.json.Value{ .object = std.json.ObjectMap.init(self.request_context.allocator()) };

        // Find the tool
        const tool = self.tools.get(name_value.string) orelse {
            const error_response = try jsonrpc.createErrorResponse(&self.request_context, request.object.get("id") orelse std.json.Value{ .null = {} }, .methodNotFound, "Tool not found");
            return try jsonrpc.stringifyValue(self.request_context.allocator(), error_response);
        };

        // Invoke the tool handler
        const result = tool.handler(&self.request_context, tool_params) catch |err| {
            std.debug.print("Error invoking tool: {}\n", .{err});
            const error_response = try jsonrpc.createErrorResponse(&self.request_context, request.object.get("id") orelse std.json.Value{ .null = {} }, .requestFailed, "Tool execution failed");
            return try jsonrpc.stringifyValue(self.request_context.allocator(), error_response);
        };

        const response = try jsonrpc.createSuccessResponse(&self.request_context, request.object.get("id") orelse std.json.Value{ .null = {} }, result);

        return try jsonrpc.stringifyValue(self.request_context.allocator(), response);
    }
};

/// Create server info object
fn createServerInfo(ctx: *jsonrpc.Context) !std.json.Value {
    const allocator = ctx.allocator();

    var server_info = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
    try server_info.object.put("name", std.json.Value{ .string = try allocator.dupe(u8, "zig-mcp") });
    try server_info.object.put("version", std.json.Value{ .string = try allocator.dupe(u8, "0.1.0") });
    return server_info;
}

/// Clone a JSON value using the given allocator
pub fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null, .bool, .integer, .float => value,
        .number_string => |s| std.json.Value{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| std.json.Value{ .string = try allocator.dupe(u8, s) },
        .array => |a| blk: {
            var new_array = std.json.Array.init(allocator);
            errdefer new_array.deinit();

            try new_array.ensureTotalCapacity(a.items.len);
            for (a.items) |item| {
                try new_array.append(try cloneJsonValue(allocator, item));
            }

            break :blk std.json.Value{ .array = new_array };
        },
        .object => |o| blk: {
            var new_object = std.json.ObjectMap.init(allocator);
            errdefer {
                var iter = new_object.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                }
                new_object.deinit();
            }

            var iter = o.iterator();
            while (iter.next()) |entry| {
                try new_object.put(try allocator.dupe(u8, entry.key_ptr.*), try cloneJsonValue(allocator, entry.value_ptr.*));
            }

            break :blk std.json.Value{ .object = new_object };
        },
    };
}
