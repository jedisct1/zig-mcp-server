# Zig MCP Server

A modular, efficient implementation of the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) in Zig. This library allows developers to integrate MCP functionality into their applications or run it as a standalone server.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)

## Features

- **Memory Efficient**: Uses arena allocators and stack buffers for optimized memory usage
- **Multiple Transports**: Supports both stdio and HTTP transports
- **Tool System**: Easy API to implement and add custom tools
- **MCP 0.4.0 compatible**: Fully compatible with the latest MCP specification
- **Pure Zig**: No external dependencies required
- **Reusable Module**: Can be used as a library in other Zig applications

## Requirements

- Zig 0.14.0 or later (tested with Zig 0.15.0-dev)

## Building

```bash
zig build -Doptimize=ReleaseSmall
```

## Running

```sh
# Run with stdio transport (default)
./zig-out/bin/mcp_server

# Run with HTTP transport
./zig-out/bin/mcp_server --transport http --port 7777

Or use the included Makefile:

```sh
# Build the project
make build

# Run with stdio transport
make run

# Run with HTTP transport
make run-http
```

## Usage

This MCP server provides the following example tools:

- `echo`: Echoes back whatever is sent to it
- `reverse`: Reverses the input string

### Command-line Options

```
Usage: mcp_server [options]

Options:
  --port, -p <port>           Port to listen on (default: 7777)
  --host, -h <host>           Host to bind to (default: 127.0.0.1)
  --transport, -t <transport> Transport to use (stdio, http) (default: stdio)
  --help                      Print this help message
```

## Example: Using with MCP clients

### Using stdio transport

```bash
./zig-out/bin/mcp_server
```

Then in another program, communicate using JSON-RPC over stdio with the MCP server.

### Using HTTP transport

```bash
./zig-out/bin/mcp_server --transport http
```

Then in a client, connect to `http://127.0.0.1:7777/jsonrpc`.

### Example Clients

The repository includes example clients:

- Python: `examples/mcp_client.py`
- JavaScript: `test_client.js`

## Using as a Library

This project can be used as a Zig module in your own applications. Here's how to include it:

### In your build.zig file

```zig
const std = @import("std");
const Dependency = std.Build.Dependency;

// In your build function
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add the zig-mcp dependency (adjust path as needed)
    const zig_mcp_dep = b.dependency("zig-mcp", .{
        .target = target,
        .optimize = optimize,
    });

    // Get the module from the dependency
    const zig_mcp_mod = zig_mcp_dep.module("zig-mcp");

    // Create your application
    const exe = b.addExecutable(.{
        .name = "my-mcp-app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the zig-mcp module to your application
    exe.addModule("zig-mcp", zig_mcp_mod);

    b.installArtifact(exe);
}
```

### In your build.zig.zon file

```zig
.{
    .name = "your-app-name",
    .version = "0.1.0",
    .dependencies = .{
        .@"zig-mcp" = .{
            .url = "https://github.com/yourusername/zig-mcp/archive/refs/tags/v0.1.0.tar.gz",
            .hash = "12345...", // Replace with actual hash
        },
    },
}
```

### Using in your code

```zig
const std = @import("std");
const zig_mcp = @import("zig-mcp");

pub fn main() !void {
    // Initialize allocator
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Define your tools
    const tools = [_]zig_mcp.mcp.Tool{
        .{
            .name = "my-tool",
            .description = "My custom tool",
            .handler = &myToolHandler,
        },
        // Use built-in tools
        zig_mcp.tool_handlers.createReverseToolWithSchema(allocator) catch unreachable,
    };

    // Create server settings
    const settings = zig_mcp.mcp.Settings{
        .transport = .stdio,  // or .http
        .host = "127.0.0.1",
        .port = 7777,
        .tools = &tools,
    };

    // Create and start MCP server
    var server = try zig_mcp.mcp.Server.init(allocator, settings);
    defer server.deinit();

    try server.start();
}

// Example custom tool handler
fn myToolHandler(ctx: *zig_mcp.jsonrpc.Context, params: std.json.Value) !std.json.Value {
    // Tool implementation
    // ...
}
```
