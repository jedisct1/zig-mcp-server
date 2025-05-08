const std = @import("std");

/// JSON-RPC 2.0 Constants
pub const VERSION = "2.0";

/// JSON-RPC 2.0 Error Codes
pub const ErrorCode = enum(i32) {
    // JSON-RPC 2.0 standard error codes
    parseError = -32700,
    invalidRequest = -32600,
    methodNotFound = -32601,
    invalidParams = -32602,
    internalError = -32603,

    // MCP specific error codes
    requestFailed = -32000,
    serverNotInitialized = -32002,
    unknownProtocolVersion = -32003,
};

/// JSON-RPC 2.0 Error type
pub const Error = error{
    parseError,
    invalidRequest,
    methodNotFound,
    invalidParams,
    internalError,
    requestFailed,
    serverNotInitialized,
    unknownProtocolVersion,

    // Additional error types for internal use
    messageIdMismatch,
};

/// Request/Response context for memory management
pub const Context = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(parent_allocator: std.mem.Allocator) Context {
        return .{
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
        };
    }

    pub fn deinit(self: *Context) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *Context) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Reset the arena, freeing all allocations at once
    pub fn reset(self: *Context) void {
        _ = self.arena.reset(.retain_capacity);
    }
};

/// Convert JSON value to string
pub fn stringifyValue(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    errdefer buffer.deinit();
    try std.json.stringify(value, .{}, buffer.writer());
    return buffer.toOwnedSlice();
}

/// Create a JSON-RPC 2.0 error response
pub fn createErrorResponse(ctx: *Context, id: std.json.Value, code: ErrorCode, message: []const u8) !std.json.Value {
    const allocator = ctx.allocator();

    var error_obj = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
    try error_obj.object.put("code", std.json.Value{ .integer = @intFromEnum(code) });
    try error_obj.object.put("message", std.json.Value{ .string = try allocator.dupe(u8, message) });

    var response = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
    try response.object.put("jsonrpc", std.json.Value{ .string = "2.0" });
    try response.object.put("id", id);
    try response.object.put("error", error_obj);

    return response;
}

/// Create a JSON-RPC 2.0 success response
pub fn createSuccessResponse(ctx: *Context, id: std.json.Value, result: std.json.Value) !std.json.Value {
    const allocator = ctx.allocator();

    var response = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
    try response.object.put("jsonrpc", std.json.Value{ .string = "2.0" });
    try response.object.put("id", id);
    try response.object.put("result", result);

    return response;
}

/// Create a JSON-RPC 2.0 notification (no response expected)
pub fn createNotification(ctx: *Context, method: []const u8, params: ?std.json.Value) !std.json.Value {
    const allocator = ctx.allocator();

    var notification = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
    try notification.object.put("jsonrpc", std.json.Value{ .string = "2.0" });
    try notification.object.put("method", std.json.Value{ .string = try allocator.dupe(u8, method) });

    if (params) |p| {
        try notification.object.put("params", p);
    }

    return notification;
}

/// Create a JSON-RPC 2.0 request
pub fn createRequest(ctx: *Context, id: std.json.Value, method: []const u8, params: ?std.json.Value) !std.json.Value {
    const allocator = ctx.allocator();

    var request = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
    try request.object.put("jsonrpc", std.json.Value{ .string = "2.0" });
    try request.object.put("id", id);
    try request.object.put("method", std.json.Value{ .string = try allocator.dupe(u8, method) });

    if (params) |p| {
        try request.object.put("params", p);
    }

    return request;
}

/// Parse a JSON-RPC 2.0 message
/// Note: The parser owns the memory of the returned JSON value.
pub fn parseMessage(ctx: *Context, message: []const u8) !std.json.Value {
    var parsed = try std.json.parseFromSlice(std.json.Value, ctx.allocator(), message, .{});
    defer parsed.deinit();

    // Deep clone is not needed here since we're working with an arena allocator
    return parsed.value;
}

/// Validate a JSON-RPC 2.0 message
pub fn validateMessage(message: std.json.Value) !void {
    if (message != .object) {
        return Error.invalidRequest;
    }

    // Check for jsonrpc field
    const jsonrpc = message.object.get("jsonrpc") orelse {
        return Error.invalidRequest;
    };

    if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, "2.0")) {
        return Error.invalidRequest;
    }

    // Check if it's a request, notification, or response
    if (message.object.get("method")) |method| {
        // It's a request or notification
        if (method != .string) {
            return Error.invalidRequest;
        }

        // If it has an id, it's a request
        if (message.object.get("id")) |id| {
            if (id != .string and id != .integer and id != .null) {
                return Error.invalidRequest;
            }
        }

        // If it has params, they must be an object or array
        if (message.object.get("params")) |params| {
            if (params != .object and params != .array) {
                return Error.invalidRequest;
            }
        }
    } else {
        // It's a response
        const id = message.object.get("id") orelse {
            return Error.invalidRequest;
        };

        if (id != .string and id != .integer and id != .null) {
            return Error.invalidRequest;
        }

        // Must have either result or error
        const has_result = message.object.get("result") != null;
        const has_error = message.object.get("error") != null;

        if (has_result == has_error) {
            return Error.invalidRequest;
        }

        // If it has an error, it must be an object with code and message
        if (has_error) {
            const error_obj = message.object.get("error").?;
            if (error_obj != .object) {
                return Error.invalidRequest;
            }

            const code = error_obj.object.get("code") orelse {
                return Error.invalidRequest;
            };

            if (code != .integer) {
                return Error.invalidRequest;
            }

            const message_field = error_obj.object.get("message") orelse {
                return Error.invalidRequest;
            };

            if (message_field != .string) {
                return Error.invalidRequest;
            }
        }
    }
}
