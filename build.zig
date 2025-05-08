const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create modules
    const net_mod = b.createModule(.{
        .root_source_file = b.path("src/net.zig"),
        .target = target,
        .optimize = optimize,
    });

    const jsonrpc_mod = b.createModule(.{
        .root_source_file = b.path("src/jsonrpc.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mcp_mod = b.createModule(.{
        .root_source_file = b.path("src/mcp.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add dependencies between modules
    mcp_mod.addImport("jsonrpc", jsonrpc_mod);
    mcp_mod.addImport("net", net_mod);

    // Create main public module
    const zig_mcp_mod = b.addModule("zig-mcp", .{
        .root_source_file = b.path("src/lib.zig"), // Will create this file
        .target = target,
        .optimize = optimize,
    });

    // Add dependencies to the main module
    zig_mcp_mod.addImport("net", net_mod);
    zig_mcp_mod.addImport("jsonrpc", jsonrpc_mod);
    zig_mcp_mod.addImport("mcp", mcp_mod);

    // Create executable
    const server_mod = b.createModule(.{
        .root_source_file = b.path("src/bin/server.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add imports to server
    server_mod.addImport("zig-mcp", zig_mcp_mod);

    const exe = b.addExecutable(.{
        .name = "mcp_server",
        .root_module = server_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Add unit tests
    const lib_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add dependencies to the test module
    lib_test_mod.addImport("net", net_mod);
    lib_test_mod.addImport("jsonrpc", jsonrpc_mod);
    lib_test_mod.addImport("mcp", mcp_mod);

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_test_mod,
    });

    const run_lib_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
}
