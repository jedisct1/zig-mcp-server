const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create modules
    const net_mod = b.createModule(.{
        .root_source_file = b.path("../src/net.zig"),
        .target = target,
        .optimize = optimize,
    });

    const jsonrpc_mod = b.createModule(.{
        .root_source_file = b.path("../src/jsonrpc.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mcp_mod = b.createModule(.{
        .root_source_file = b.path("../src/mcp.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add dependencies
    mcp_mod.addImport("jsonrpc", jsonrpc_mod);
    mcp_mod.addImport("net", net_mod);

    const zig_mcp_mod = b.createModule(.{
        .root_source_file = b.path("../src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    zig_mcp_mod.addImport("net", net_mod);
    zig_mcp_mod.addImport("jsonrpc", jsonrpc_mod);
    zig_mcp_mod.addImport("mcp", mcp_mod);

    // Create the executable module
    const lib_example_mod = b.createModule(.{
        .root_source_file = b.path("lib_example.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add module imports
    lib_example_mod.addImport("zig-mcp", zig_mcp_mod);

    // Create executable
    const exe = b.addExecutable(.{
        .name = "lib_example",
        .root_module = lib_example_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);
}
