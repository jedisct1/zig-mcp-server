const std = @import("std");

/// HTTP Server implementation
pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    address: std.net.Address,
    server: std.net.Server,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !HttpServer {
        const address = try std.net.Address.resolveIp(host, port);
        const server = try address.listen(.{
            .reuse_address = true,
        });

        return HttpServer{
            .allocator = allocator,
            .address = address,
            .server = server,
        };
    }

    pub fn deinit(self: *HttpServer) void {
        self.server.deinit();
    }

    pub fn listen(self: *HttpServer, handler: *const fn (*Connection) anyerror!void) !void {
        while (true) {
            const conn = try self.server.accept();
            var connection = Connection{
                .allocator = self.allocator,
                .stream = conn.stream,
                .address = conn.address,
            };

            // In a production system, we would spawn a thread or use an event loop
            // For simplicity, we'll handle connections sequentially
            handler(&connection) catch |err| {
                std.debug.print("Error handling connection: {}\n", .{err});
            };
        }
    }
};

/// HTTP Connection
pub const Connection = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    address: std.net.Address,

    pub fn deinit(self: *Connection) void {
        self.stream.close();
    }

    pub fn read(self: *Connection, buffer: []u8) !usize {
        return self.stream.read(buffer);
    }

    pub fn write(self: *Connection, buffer: []const u8) !usize {
        return self.stream.write(buffer);
    }

    pub fn writeAll(self: *Connection, buffer: []const u8) !void {
        return self.stream.writeAll(buffer);
    }

    /// Send an HTTP response
    pub fn sendResponse(self: *Connection, status_code: u16, content_type: []const u8, body: []const u8) !void {
        // Use stack-allocated buffer for static strings where possible
        const status_message = switch (status_code) {
            200 => "OK",
            400 => "Bad Request",
            404 => "Not Found",
            500 => "Internal Server Error",
            else => "Unknown",
        };

        // Build status line
        var status_line_buf: [128]u8 = undefined;
        const status_line = try std.fmt.bufPrint(&status_line_buf, "HTTP/1.1 {d} {s}\r\n", .{ status_code, status_message });
        try self.writeAll(status_line);

        // Content-Type header
        try self.writeAll("Content-Type: ");
        try self.writeAll(content_type);
        try self.writeAll("\r\n");

        // Content-Length header
        var content_length_buf: [64]u8 = undefined;
        const content_length = try std.fmt.bufPrint(&content_length_buf, "Content-Length: {d}\r\n", .{body.len});
        try self.writeAll(content_length);

        // Connection header and end of headers
        try self.writeAll("Connection: close\r\n\r\n");

        // Body
        try self.writeAll(body);
    }

    /// Parse HTTP request
    pub fn parseRequest(self: *Connection) !HttpRequest {
        // Use stack buffer for the HTTP request
        var buffer: [8192]u8 = undefined;
        const bytes_read = try self.read(&buffer);
        if (bytes_read == 0) {
            return error.ConnectionClosed;
        }

        const data = buffer[0..bytes_read];

        // Find the end of the request line
        const request_line_end = std.mem.indexOf(u8, data, "\r\n") orelse {
            return error.InvalidRequest;
        };

        const request_line = data[0..request_line_end];

        // Split the request line into method, path, and version
        var request_line_iter = std.mem.splitScalar(u8, request_line, ' ');
        const method = request_line_iter.next() orelse {
            return error.InvalidRequest;
        };
        const path = request_line_iter.next() orelse {
            return error.InvalidRequest;
        };
        const version = request_line_iter.next() orelse {
            return error.InvalidRequest;
        };

        // Find the end of the headers
        const headers_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse {
            return error.InvalidRequest;
        };

        const body_start = headers_end + 4;
        const body = if (body_start < bytes_read) data[body_start..] else "";

        return HttpRequest{
            .method = try self.allocator.dupe(u8, method),
            .path = try self.allocator.dupe(u8, path),
            .version = try self.allocator.dupe(u8, version),
            .body = try self.allocator.dupe(u8, body),
            .allocator = self.allocator,
        };
    }
};

/// HTTP Request
pub const HttpRequest = struct {
    allocator: std.mem.Allocator,
    method: []const u8,
    path: []const u8,
    version: []const u8,
    body: []const u8,

    pub fn deinit(self: *HttpRequest) void {
        self.allocator.free(self.method);
        self.allocator.free(self.path);
        self.allocator.free(self.version);
        self.allocator.free(self.body);
    }
};
