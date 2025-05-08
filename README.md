# Zig MCP Server

<div align="center">
<h3>A high-performance implementation of the MCP protocol in Zig</h3>

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
</div>

---

The Zig MCP Server is a memory-efficient implementation of the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) specification. It provides both a standalone server executable and a library that can be embedded into your Zig applications.

## Features

- **Enhanced HTTP Server**:
  - Threaded connection handling with configurable thread pool
  - Connection limiting to prevent resource exhaustion
  - Graceful shutdown support
  - Connection timeout management
  - Server metrics collection
  - Health check endpoint
- **Memory Efficient**: Uses arena allocators and stack buffers for optimized memory usage
- **Multiple Transports**: Supports both stdio and HTTP transports
- **Tool System**: Easy API to implement and add custom tools
- **MCP 0.4.0 Compatible**: Fully compatible with the latest MCP specification
- **Pure Zig**: No external dependencies required
- **Reusable Module**: Can be used as a library in other Zig applications
- **WebAssembly Support**: Runs on function-as-a-service cloud services based on WebAssembly, such as Fastly Compute

## Requirements

- Zig 0.14.0 or later (tested with Zig 0.15.0-dev)

## Building

```bash
# Standard build
zig build

# Optimized for release
zig build -Doptimize=ReleaseSmall
```

## Running

### Using the Command Line

```bash
# Run with stdio transport (default)
./zig-out/bin/mcp_server

# Run with HTTP transport
./zig-out/bin/mcp_server --transport http --port 7777

# Run with custom thread count and connection limits
./zig-out/bin/mcp_server --transport http --threads 4 --max-connections 500 --timeout 60000
```

### Using the Makefile

```bash
# Build the project
make build

# Run with stdio transport
make run

# Run with HTTP transport
make run-http
```

## Usage

### Standalone Server

The standalone server provides ready-to-use MCP functionality with minimal setup.

#### Built-in Tools

This MCP server comes with the following example tools out of the box:

- `echo`: Echoes back any provided parameters
- `reverse`: Takes a string input and returns its reverse

#### Command-line Options

```
Usage: mcp_server [options]

Options:
  --port, -p <port>                  Port to listen on (default: 7777)
  --host, -h <host>                  Host to bind to (default: 127.0.0.1)
  --transport, -t <transport>        Transport to use (stdio, http) (default: stdio)
  --threads, -j <count>              Number of worker threads (default: CPU core count)
  --max-connections, -c <count>      Maximum concurrent connections (default: 1000)
  --timeout, -T <milliseconds>       Connection timeout in milliseconds (default: 30000, 0 = no timeout)
  --help                             Print this help message

Server Endpoints:
  /jsonrpc                           Main JSON-RPC endpoint (POST)
  /health                            Health check endpoint (GET)
```

#### Advanced Usage

##### Threading Model

The HTTP transport uses a thread pool for handling concurrent connections. By default, it uses a number of threads equal to the available CPU cores, but you can adjust this with the `--threads` option.

##### Connection Limiting

To prevent resource exhaustion, you can limit the number of concurrent connections using the `--max-connections` option. When this limit is reached, new connections will be rejected.

##### Non-blocking Mode

Use the `--non-blocking` option to run the HTTP server in non-blocking mode. This starts a dedicated thread for the server, allowing the main thread to perform other tasks. This is especially useful when using the library in applications that need to do other work while the server is running.

##### Connection Timeouts

Each connection has a configurable timeout (default: 30 seconds) after which inactive connections are automatically closed. Set to 0 to disable timeouts completely.

##### Graceful Shutdown

The server supports graceful shutdown, which allows in-flight requests to complete before the server exits. This prevents abruptly terminating active connections during shutdown.

##### Server Metrics and Health Checks

The HTTP server provides metrics tracking, including:
- Total connections handled
- Active connections
- Bytes sent and received
- Request success/failure rates

A basic health endpoint at `/health` returns server status information.

## Client Examples

The server can be used with any client that implements the MCP protocol. We provide several example clients for demonstration.

### Python Client

Run the server first:

```bash
./zig-out/bin/mcp_server --transport http
```

Then run the Python client:

```bash
# Install required dependencies
pip install requests

# Run the example client
python examples/mcp_client.py --transport http --url "http://127.0.0.1:7777/jsonrpc"
```

The Python client demonstrates:
- Establishing a connection to the MCP server
- Protocol initialization and handshake
- Listing available tools
- Invoking tools with parameters
- Handling responses and errors

### JavaScript Client

For a Node.js client example:

```bash
# Make the script executable
chmod +x test_client.js

# Run the client (automatically starts the server in stdio mode)
./test_client.js
```

This JavaScript client shows:
- Communication over stdio transport
- Asynchronous MCP operation
- Proper request/response handling

### Building Your Own Client

The MCP protocol is based on JSON-RPC 2.0, making it easy to implement clients in any language. Key points to follow:

1. **Initialization**: Send an `initialize` request with your client capabilities
2. **Tool Discovery**: Use `mcp/tools/list` to discover available tools
3. **Tool Invocation**: Use `mcp/tools/invoke` with the tool name and parameters
4. **Shutdown**: Send a `shutdown` request when done

### Building for WebAssembly

The server can be compiled to WebAssembly for deployment in serverless environments:

```bash
zig build -Dtarget=wasm32-wasi -Doptimize=ReleaseSmall
```

This allows you to run the MCP server in WASI-compatible serverless environments.

## Library Integration

Zig MCP Server is designed to be easily embedded in your Zig applications as a library.

### Adding the Dependency

#### In your build.zig file

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add the zig-mcp dependency
    const zig_mcp_dep = b.dependency("zig-mcp", .{
        .target = target,
        .optimize = optimize,
    });

    // Get the module from the dependency
    const zig_mcp_mod = zig_mcp_dep.module("zig-mcp");

    // Create your application
    const exe = b.addExecutable(.{
        .name = "my_mcp_app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the zig-mcp module to your application
    exe.addModule("zig-mcp", zig_mcp_mod);

    b.installArtifact(exe);
}
```

#### In your build.zig.zon file

```zig
.{
    .name = "your_app_name",
    .version = "0.1.0",
    .dependencies = .{
        .@"zig-mcp" = .{
            .url = "https://github.com/yourusername/zig-mcp/archive/refs/tags/v0.1.0.tar.gz",
            .hash = "12345...", // Replace with actual hash
        },
    },
}
```

### Basic Integration Example

Here's a simple example showing how to integrate the MCP server into your application:

```zig
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

    // Configure server settings with HTTP transport
    const settings = zig_mcp.mcp.Settings{
        .transport = .http,
        .host = "127.0.0.1",
        .port = 7777,
        .tools = &tools,
        .max_connections = 100,                  // Max 100 concurrent connections
        .thread_count = 4,                       // 4 worker threads
        .connection_timeout_ms = 30000,          // 30 second connection timeout
        .non_blocking_http = true,               // Run in non-blocking mode
    };

    // Create and start MCP server
    var server = try zig_mcp.mcp.Server.init(allocator, settings);
    defer server.deinit();

    std.debug.print("MCP Server starting\n", .{});
    try server.start();

    std.debug.print("Server running in background, you can continue with other tasks...\n", .{});

    // Since we're using non-blocking mode, the main thread can do other work
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        std.time.sleep(5 * std.time.ns_per_s); // Sleep for 5 seconds
        std.debug.print("Main thread still active...\n", .{});
    }

    std.debug.print("Main application shutting down\n", .{});

    // Explicitly request a graceful shutdown before the defer
    server.shutdown();
    std.debug.print("Server shutdown requested, waiting for completion...\n", .{});

    // Allow some time for the shutdown to complete
    std.time.sleep(1 * std.time.ns_per_s);
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
```

### Advanced Integration

#### Custom Tool Development

Creating custom tools is straightforward:

1. Implement a handler function with the `zig_mcp.mcp.ToolHandlerFn` signature
2. Add it to the tools list when configuring your server
3. Optionally include a JSON Schema definition for tool parameters

```zig
fn myComplexTool(ctx: *zig_mcp.jsonrpc.Context, params: std.json.Value) !std.json.Value {
    const allocator = ctx.allocator();

    // Extract and validate parameters
    const value1 = params.object.get("value1") orelse return zig_mcp.jsonrpc.Error.invalidParams;
    const value2 = params.object.get("value2") orelse return zig_mcp.jsonrpc.Error.invalidParams;

    if (value1 != .integer or value2 != .integer) {
        return zig_mcp.jsonrpc.Error.invalidParams;
    }

    // Business logic
    const result_value = value1.integer * value2.integer;

    // Format and return result
    var result = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
    try result.object.put("calculated_value", std.json.Value{ .integer = result_value });

    return result;
}
```

#### Transport Configuration

Choose the appropriate transport for your application:

- **HTTP Transport**: Ideal for networked applications, supports high concurrency
- **Stdio Transport**: Perfect for CLI tools and direct integration with LLM systems

#### Memory Management

The server uses an arena allocator for each request, automatically handling cleanup after each request/response cycle to prevent memory leaks.

## Current Status and Future Work

This project is under active development. The server has been improved with threading support, connection limiting, and timeouts, but several areas still need work:

1. **Stability Improvements**: Address potential panics during connection handling
2. **Stress Testing**: Verify behavior under high load and concurrent connections
3. **Secure Transport**: Add TLS support for secure connections
4. **Robust HTTP Parser**: Improve the HTTP parser to handle all edge cases
5. **Complete Error Handling**: Better error handling and recovery mechanisms
6. **Enhanced Logging**: More comprehensive logging system with different verbosity levels
7. **Connection Pooling**: For better performance with HTTP keep-alive
8. **Automated Tests**: Expand test coverage, especially for concurrency
