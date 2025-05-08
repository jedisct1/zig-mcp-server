const std = @import("std");
const net = @import("net.zig");
const jsonrpc = @import("jsonrpc.zig");
const mcp = @import("mcp.zig");

pub fn main() !void {
    // Initialize allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }){};
    const allocator = gpa.allocator();
    defer {
        const check = gpa.deinit();
        if (check == .leak) {
            std.debug.print("MEMORY LEAK DETECTED!\n", .{});
        }
    }

    // Parse command line arguments
    var args_it = try std.process.argsWithAllocator(allocator);
    defer args_it.deinit();

    // Skip program name
    _ = args_it.skip();

    // Default settings with static strings for tool names and descriptions
    const tools = [_]mcp.Tool{
        .{
            .name = "echo",
            .description = "Echoes back whatever is sent to it",
            .handler = &echoHandler,
        },
        .{
            .name = "reverse",
            .description = "Reverses the input string",
            .handler = &reverseHandler,
        },
    };

    var settings = mcp.Settings{
        .port = 7777,
        .host = "127.0.0.1",
        .transport = .stdio,
        .tools = &tools,
        .max_connections = 1000, // Default to 1000 max connections
        .thread_count = null, // Default to auto-detect (based on CPU cores)
        .connection_timeout_ms = 30000, // Default to 30 seconds timeout
        .backlog_size = 128, // Default to 128 connections backlog
        .non_blocking_http = false, // Default to blocking HTTP server
    };

    // Parse command line arguments using stack-allocated buffer
    var arg_buf: [256]u8 = undefined;
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            if (args_it.next()) |port_str| {
                settings.port = try std.fmt.parseInt(u16, port_str, 10);
            }
        } else if (std.mem.eql(u8, arg, "--host") or std.mem.eql(u8, arg, "-h")) {
            if (args_it.next()) |host| {
                // Copy host to static buffer
                if (host.len < arg_buf.len) {
                    @memcpy(arg_buf[0..host.len], host);
                    settings.host = arg_buf[0..host.len];
                } else {
                    std.debug.print("Host name too long, using default\n", .{});
                }
            }
        } else if (std.mem.eql(u8, arg, "--transport") or std.mem.eql(u8, arg, "-t")) {
            if (args_it.next()) |transport| {
                if (std.mem.eql(u8, transport, "stdio")) {
                    settings.transport = .stdio;
                } else if (std.mem.eql(u8, transport, "http")) {
                    settings.transport = .http;
                } else {
                    std.debug.print("Unknown transport: {s}. Using default.\n", .{transport});
                }
            }
        } else if (std.mem.eql(u8, arg, "--threads") or std.mem.eql(u8, arg, "-j")) {
            if (args_it.next()) |threads_str| {
                settings.thread_count = try std.fmt.parseInt(usize, threads_str, 10);
            }
        } else if (std.mem.eql(u8, arg, "--max-connections") or std.mem.eql(u8, arg, "-c")) {
            if (args_it.next()) |conn_str| {
                settings.max_connections = try std.fmt.parseInt(usize, conn_str, 10);
            }
        } else if (std.mem.eql(u8, arg, "--timeout") or std.mem.eql(u8, arg, "-T")) {
            if (args_it.next()) |timeout_str| {
                settings.connection_timeout_ms = try std.fmt.parseInt(u32, timeout_str, 10);
            }
        } else if (std.mem.eql(u8, arg, "--backlog") or std.mem.eql(u8, arg, "-b")) {
            if (args_it.next()) |backlog_str| {
                settings.backlog_size = try std.fmt.parseInt(u32, backlog_str, 10);
            }
        } else if (std.mem.eql(u8, arg, "--non-blocking")) {
            settings.non_blocking_http = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        }
    }

    // Create and start MCP server
    var server = try mcp.Server.init(allocator, settings);
    defer server.deinit();

    std.debug.print("MCP Server starting with transport: {s}\n", .{@tagName(settings.transport)});
    if (settings.transport == .http) {
        const thread_count_str = if (settings.thread_count) |tc|
            std.fmt.allocPrint(allocator, "{d}", .{tc}) catch "(error)"
        else
            "(auto)";

        const max_connections = settings.max_connections orelse 1000;
        const timeout_str = if (settings.connection_timeout_ms == 0)
            "disabled"
        else
            std.fmt.allocPrint(allocator, "{d}ms", .{settings.connection_timeout_ms}) catch "?";

        defer {
            if (settings.thread_count != null and !std.mem.eql(u8, thread_count_str, "(error)"))
                allocator.free(@as([]u8, @constCast(thread_count_str)));

            if (settings.connection_timeout_ms != 0 and !std.mem.eql(u8, timeout_str, "?"))
                allocator.free(@as([]u8, @constCast(timeout_str)));
        }

        std.debug.print("Listening on http://{s}:{d} with {s} threads, {d} max connections, timeout: {s}\n", .{ settings.host, settings.port, thread_count_str, max_connections, timeout_str });
    }

    try server.start();
}

fn printHelp() void {
    // Use comptime string for help text
    const help_text =
        \\Usage: zig-mcp [options]
        \\
        \\Options:
        \\  --port, -p <port>                  Port to listen on (default: 7777)
        \\  --host, -h <host>                  Host to bind to (default: 127.0.0.1)
        \\  --transport, -t <transport>        Transport to use (stdio, http) (default: stdio)
        \\  --threads, -j <count>              Number of worker threads (default: CPU core count)
        \\  --max-connections, -c <count>      Maximum concurrent connections (default: 1000)
        \\  --timeout, -T <milliseconds>       Connection timeout in milliseconds (default: 30000, 0 = no timeout)
        \\  --backlog, -b <count>              TCP connection backlog size (default: 128)
        \\  --non-blocking                     Run HTTP server in non-blocking mode
        \\  --help                             Print this help message
        \\
        \\Server Endpoints:
        \\  /jsonrpc                           Main JSON-RPC endpoint (POST)
        \\  /health                            Health check endpoint (GET)
        \\
    ;
    std.debug.print("{s}", .{help_text});
}

// Tool handler implementations
fn echoHandler(ctx: *jsonrpc.Context, params: std.json.Value) !std.json.Value {
    // For echo, we just need to clone the params into our context
    return try mcp.cloneJsonValue(ctx.allocator(), params);
}

fn reverseHandler(ctx: *jsonrpc.Context, params: std.json.Value) !std.json.Value {
    // Get the allocator from the context
    const allocator = ctx.allocator();

    // Check if params has a "text" field
    const text_value = params.object.get("text") orelse {
        return jsonrpc.Error.invalidParams;
    };

    if (text_value != .string) {
        return jsonrpc.Error.invalidParams;
    }

    const text = text_value.string;

    // Use stack buffer for small strings, fall back to heap for larger ones
    var stack_buf: [1024]u8 = undefined;
    const reversed = if (text.len <= stack_buf.len) blk: {
        // Reverse the string in stack buffer
        for (text, 0..) |char, i| {
            stack_buf[text.len - 1 - i] = char;
        }
        // Allocate a copied string in our arena
        break :blk try allocator.dupe(u8, stack_buf[0..text.len]);
    } else blk: {
        // For larger strings, use heap allocation
        var heap_buf = try allocator.alloc(u8, text.len);
        // Reverse the string
        for (text, 0..) |char, i| {
            heap_buf[text.len - 1 - i] = char;
        }
        break :blk heap_buf;
    };

    // Create response object
    var result = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
    try result.object.put("reversed", std.json.Value{ .string = reversed });

    return result;
}

// Export tests
test {
    std.testing.refAllDecls(@This());
}
