const std = @import("std");
const zig_mcp = @import("zig-mcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Define your tools
    const tools = [_]zig_mcp.mcp.Tool{
        .{
            .name = "hello",
            .description = "Greeting tool",
            .handler = &helloHandler,
        },
    };

    // Configure server settings - use stdio transport instead of HTTP to avoid socket issues
    const settings = zig_mcp.mcp.Settings{
        .transport = .stdio,
        .tools = &tools,
    };

    // Create and start MCP server
    var server = try zig_mcp.mcp.Server.init(allocator, settings);
    defer server.deinit();

    std.debug.print("MCP Server starting\n", .{});

    // Start the server in a separate thread since the stdio transport is blocking
    var serverThread: ?std.Thread = null;

    serverThread = try std.Thread.spawn(.{}, struct {
        fn runServer(srv: *zig_mcp.mcp.Server) !void {
            try srv.start();
        }
    }.runServer, .{&server});

    std.debug.print("Server running in background, you can continue with other tasks...\n", .{});

    // Since we're running in a separate thread, the main thread can do other work
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        std.time.sleep(2 * std.time.ns_per_s); // Sleep for 2 seconds
        std.debug.print("Main thread still active...\n", .{});
    }

    std.debug.print("Main application shutting down\n", .{});
    // Explicitly request a graceful shutdown
    server.shutdown();
    std.debug.print("Server shutdown requested, waiting for completion...\n", .{});

    // Wait for the server thread to complete
    if (serverThread) |thread| {
        thread.join();
    }

    std.debug.print("Server thread has joined, cleaning up resources...\n", .{});
    // Server resources will be cleaned up when server variable is dropped
}

// Tool handler implementation
fn helloHandler(ctx: *zig_mcp.jsonrpc.Context, params: std.json.Value) !std.json.Value {
    const allocator = ctx.allocator();

    // Extract name parameter if present
    const name = if (params.object.get("name")) |n|
        if (n == .string) n.string else "world"
    else
        "world";

    // Build response
    var result = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
    const greeting = try std.fmt.allocPrint(allocator, "Hello, {s}!", .{name});
    try result.object.put("greeting", std.json.Value{ .string = greeting });

    return result;
}
