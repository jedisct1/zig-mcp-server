const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const mcp = @import("mcp.zig");

/// Example tool handlers that can be used in applications
/// Echo handler that returns the input parameters unchanged
pub fn echoHandler(ctx: *jsonrpc.Context, params: std.json.Value) !std.json.Value {
    // For echo, we just need to clone the params into our context
    return try mcp.cloneJsonValue(ctx.allocator(), params);
}

/// Reverse handler that reverses a text string
pub fn reverseHandler(ctx: *jsonrpc.Context, params: std.json.Value) !std.json.Value {
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

// Example tool with parameters schema
pub fn createReverseToolWithSchema(allocator: std.mem.Allocator) !mcp.Tool {
    // Create a JSON Schema for the parameters
    var schema = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
    try schema.object.put("type", std.json.Value{ .string = "object" });

    var properties = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
    var text_prop = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
    try text_prop.object.put("type", std.json.Value{ .string = "string" });
    try text_prop.object.put("description", std.json.Value{ .string = "The text to reverse" });

    try properties.object.put("text", text_prop);
    try schema.object.put("properties", properties);

    var required = std.json.Value{ .array = std.json.Array.init(allocator) };
    try required.array.append(std.json.Value{ .string = "text" });
    try schema.object.put("required", required);

    return mcp.Tool{
        .name = "reverse",
        .description = "Reverses the input string",
        .handler = reverseHandler,
        .parameters = schema,
    };
}

test {
    std.testing.refAllDecls(@This());
}
