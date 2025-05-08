const std = @import("std");
const testing = std.testing;
const mcp = @import("mcp.zig");
const jsonrpc = @import("jsonrpc.zig");

// Test tool handlers
fn testEchoHandler(allocator: std.mem.Allocator, params: std.json.Value) !std.json.Value {
    return params;
}

fn testReverseHandler(allocator: std.mem.Allocator, params: std.json.Value) !std.json.Value {
    // Check if params has a "text" field
    const text_value = params.object.get("text") orelse {
        return jsonrpc.Error.invalidParams;
    };

    if (text_value != .string) {
        return jsonrpc.Error.invalidParams;
    }

    const text = text_value.string;

    // Allocate buffer for the reversed string
    var reversed = try allocator.alloc(u8, text.len);
    defer allocator.free(reversed);

    // Reverse the string
    for (text, 0..) |char, i| {
        reversed[text.len - 1 - i] = char;
    }

    // Create response object
    var result = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
    try result.object.put("reversed", std.json.Value{ .string = try allocator.dupe(u8, reversed) });

    return result;
}

test "MCP Server Initialization" {
    // Create a test allocator
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create MCP server
    var server = try mcp.Server.init(allocator, .{
        .tools = &[_]mcp.Tool{
            .{
                .name = "test_echo",
                .description = "Test echo tool",
                .handler = &testEchoHandler,
            },
            .{
                .name = "test_reverse",
                .description = "Test reverse tool",
                .handler = &testReverseHandler,
            },
        },
    });

    // Initialize the array element to an invalid value first
    // Fix for Zig 0.14 compiler - to avoid uninitialized memory errors
    mcp.g_server = undefined;
    defer server.deinit();

    // Test initialization with a valid request
    const init_request =
        \\ {
        \\   "jsonrpc": "2.0",
        \\   "id": 1,
        \\   "method": "initialize",
        \\   "params": {
        \\     "protocolVersion": "0.4.0",
        \\     "capabilities": {
        \\       "tools": {
        \\         "enabled": true
        \\       }
        \\     }
        \\   }
        \\ }
    ;

    const init_response = try server.handleRequest(init_request);
    const init_response_parsed = try std.json.parseFromSlice(std.json.Value, allocator, init_response, .{});

    try testing.expectEqual(std.json.Value.Tag.object, init_response_parsed.value.tag);
    try testing.expect(init_response_parsed.value.object.contains("result"));

    const result = init_response_parsed.value.object.get("result").?;
    try testing.expectEqual(std.json.Value.Tag.object, result.tag);
    try testing.expect(result.object.contains("capabilities"));
    try testing.expect(result.object.contains("serverInfo"));

    const capabilities = result.object.get("capabilities").?;
    try testing.expectEqual(std.json.Value.Tag.object, capabilities.tag);
    try testing.expect(capabilities.object.contains("protocolVersion"));
    try testing.expect(capabilities.object.contains("tools"));

    const protocol_version = capabilities.object.get("protocolVersion").?;
    try testing.expectEqual(std.json.Value.Tag.string, protocol_version.tag);
    try testing.expectEqualStrings(mcp.PROTOCOL_VERSION, protocol_version.string);
}

test "MCP Server Tools" {
    // Create a test allocator
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create MCP server
    var server = try mcp.Server.init(allocator, .{
        .tools = &[_]mcp.Tool{
            .{
                .name = "test_echo",
                .description = "Test echo tool",
                .handler = &testEchoHandler,
            },
            .{
                .name = "test_reverse",
                .description = "Test reverse tool",
                .handler = &testReverseHandler,
            },
        },
    });

    // Initialize the array element to an invalid value first
    // Fix for Zig 0.14 compiler - to avoid uninitialized memory errors
    mcp.g_server = undefined;
    defer server.deinit();

    // Initialize the server first
    const init_request =
        \\ {
        \\   "jsonrpc": "2.0",
        \\   "id": 1,
        \\   "method": "initialize",
        \\   "params": {
        \\     "protocolVersion": "0.4.0",
        \\     "capabilities": {
        \\       "tools": {
        \\         "enabled": true
        \\       }
        \\     }
        \\   }
        \\ }
    ;

    _ = try server.handleRequest(init_request);

    // Send initialized notification
    const initialized_request =
        \\ {
        \\   "jsonrpc": "2.0",
        \\   "method": "initialized"
        \\ }
    ;

    _ = try server.handleRequest(initialized_request);

    // Test listing tools
    const list_tools_request =
        \\ {
        \\   "jsonrpc": "2.0",
        \\   "id": 2,
        \\   "method": "mcp/tools/list"
        \\ }
    ;

    const list_tools_response = try server.handleRequest(list_tools_request);
    const list_tools_parsed = try std.json.parseFromSlice(std.json.Value, allocator, list_tools_response, .{});

    try testing.expectEqual(std.json.Value.Tag.object, list_tools_parsed.value.tag);
    try testing.expect(list_tools_parsed.value.object.contains("result"));

    const list_result = list_tools_parsed.value.object.get("result").?;
    try testing.expectEqual(std.json.Value.Tag.object, list_result.tag);
    try testing.expect(list_result.object.contains("tools"));

    const tools = list_result.object.get("tools").?;
    try testing.expectEqual(std.json.Value.Tag.array, tools.tag);
    try testing.expectEqual(@as(usize, 2), tools.array.items.len);

    // Test invoking the echo tool
    const invoke_echo_request =
        \\ {
        \\   "jsonrpc": "2.0",
        \\   "id": 3,
        \\   "method": "mcp/tools/invoke",
        \\   "params": {
        \\     "name": "test_echo",
        \\     "params": {
        \\       "message": "Hello, MCP!"
        \\     }
        \\   }
        \\ }
    ;

    const invoke_echo_response = try server.handleRequest(invoke_echo_request);
    const invoke_echo_parsed = try std.json.parseFromSlice(std.json.Value, allocator, invoke_echo_response, .{});

    try testing.expectEqual(std.json.Value.Tag.object, invoke_echo_parsed.value.tag);
    try testing.expect(invoke_echo_parsed.value.object.contains("result"));

    const echo_result = invoke_echo_parsed.value.object.get("result").?;
    try testing.expectEqual(std.json.Value.Tag.object, echo_result.tag);
    try testing.expect(echo_result.object.contains("message"));

    const message = echo_result.object.get("message").?;
    try testing.expectEqual(std.json.Value.Tag.string, message.tag);
    try testing.expectEqualStrings("Hello, MCP!", message.string);

    // Test invoking the reverse tool
    const invoke_reverse_request =
        \\ {
        \\   "jsonrpc": "2.0",
        \\   "id": 4,
        \\   "method": "mcp/tools/invoke",
        \\   "params": {
        \\     "name": "test_reverse",
        \\     "params": {
        \\       "text": "Hello, MCP!"
        \\     }
        \\   }
        \\ }
    ;

    const invoke_reverse_response = try server.handleRequest(invoke_reverse_request);
    const invoke_reverse_parsed = try std.json.parseFromSlice(std.json.Value, allocator, invoke_reverse_response, .{});

    try testing.expectEqual(std.json.Value.Tag.object, invoke_reverse_parsed.value.tag);
    try testing.expect(invoke_reverse_parsed.value.object.contains("result"));

    const reverse_result = invoke_reverse_parsed.value.object.get("result").?;
    try testing.expectEqual(std.json.Value.Tag.object, reverse_result.tag);
    try testing.expect(reverse_result.object.contains("reversed"));

    const reversed = reverse_result.object.get("reversed").?;
    try testing.expectEqual(std.json.Value.Tag.string, reversed.tag);
    try testing.expectEqualStrings("!PCM ,olleH", reversed.string);
}
