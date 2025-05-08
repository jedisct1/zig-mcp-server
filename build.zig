const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    // Create main module and add imports
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_mod.addImport("net", net_mod);
    main_mod.addImport("jsonrpc", jsonrpc_mod);
    main_mod.addImport("mcp", mcp_mod);

    // Create executable
    const exe = b.addExecutable(.{
        .name = "mcp_server",
        .root_module = main_mod,
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
    const unit_tests = b.addTest(.{
        .root_module = main_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
