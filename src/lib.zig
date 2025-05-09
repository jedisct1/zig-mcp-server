const std = @import("std");
const builtin = @import("builtin");

// Detect WebAssembly target
const is_wasm = builtin.cpu.arch.isWasm();

/// Re-export MCP modules
pub const mcp = @import("mcp.zig");
pub const jsonrpc = @import("jsonrpc.zig");
// Only export net.zig on non-WebAssembly targets
pub const net = if (!is_wasm) @import("net.zig") else struct {};
pub const tool_handlers = @import("tools.zig");

/// Version of the zig-mcp library
pub const VERSION = "0.1.0";

/// Simple helper function to initialize and run an MCP server with custom tools
pub fn createServer(
    allocator: std.mem.Allocator,
    tool_list: []const mcp.Tool,
    transport_type: mcp.TransportType,
    host: []const u8,
    port: u16,
) !mcp.Server {
    if (is_wasm) {
        // In WebAssembly, we only use stdio transport and ignore host/port
        const settings = mcp.Settings{
            .transport = .stdio, // Force stdio for WebAssembly
            .tools = tool_list,
        };
        return try mcp.Server.init(allocator, settings);
    } else {
        // For non-WebAssembly platforms, use all parameters
        const settings = mcp.Settings{
            .transport = transport_type,
            .host = host,
            .port = port,
            .tools = tool_list,
        };
        return try mcp.Server.init(allocator, settings);
    }
}

/// Create a tool definition with the given name, description and handler
pub fn createTool(
    name: []const u8,
    description: []const u8,
    handler: mcp.ToolHandlerFn,
    parameters: ?std.json.Value,
) mcp.Tool {
    return .{
        .name = name,
        .description = description,
        .handler = handler,
        .parameters = parameters,
    };
}

test "main export test" {
    // This test imports and exercises all exported items
    _ = mcp;
    _ = jsonrpc;
    if (!is_wasm) {
        // Net module only available on non-WebAssembly platforms
        _ = net;
    }
    _ = tool_handlers;
    _ = VERSION;
    _ = createServer;
    _ = createTool;

    // Test basic module functionality
    const std_test = std.testing;

    // Mock a tool handler function for tests
    var test_context = jsonrpc.Context.init(std_test.allocator);
    defer test_context.deinit();

    // Create a test JSON value
    var test_value = std.json.Value{ .object = std.json.ObjectMap.init(test_context.allocator()) };
    try test_value.object.put("test", std.json.Value{ .string = "value" });

    // Create a tool with our mock handler
    const test_tool = createTool(
        "test_tool",
        "A test tool",
        testHandler,
        null,
    );

    // Basic validation of the tool
    try std_test.expectEqualStrings("test_tool", test_tool.name);
    try std_test.expectEqualStrings("A test tool", test_tool.description);
}

// Test handler function for tests
fn testHandler(ctx: *jsonrpc.Context, params: std.json.Value) !std.json.Value {
    _ = params;
    var result = std.json.Value{ .object = std.json.ObjectMap.init(ctx.allocator()) };
    try result.object.put("success", std.json.Value{ .bool = true });
    return result;
}

// Ensure all public declarations are tested
test {
    std.testing.refAllDecls(@This());
}
