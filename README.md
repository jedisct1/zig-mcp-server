# Zig MCP Server

Am efficient implementation of the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) in Zig. This server allows AI applications to connect and use tools provided by the server.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)

## Features

- **Memory Efficient**: Uses arena allocators and stack buffers for optimized memory usage
- **Multiple Transports**: Supports both stdio and HTTP transports
- **Tool System**: Easy API to implement and add custom tools
- **MCP 0.4.0 compatible**: Fully compatible with the latest MCP specification
- **Pure Zig**: No external dependencies required

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
