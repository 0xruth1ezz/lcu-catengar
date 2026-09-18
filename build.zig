const std = @import("std");
const native = @import("native_sdk");

pub fn build(b: *std.Build) void {
    const app = native.addAppArtifacts(b, b.dependency("native_sdk", .{}), .{ .name = "catengar" });
    const options = b.addOptions();
    options.addOption([]const u8, "preview_catalog", b.option([]const u8, "preview-catalog", "Read-only UI preview using a local catalog fixture (no LCU connection or settings writes)") orelse "");
    app.exe.root_module.addOptions("catengar_options", options);
    app.exe.root_module.linkSystemLibrary("winhttp", .{});
    app.exe.root_module.addAnonymousImport("catengar_icon", .{ .root_source_file = b.path("assets/catengar.ico") });
    app.exe.root_module.addWin32ResourceFile(.{ .file = b.path("assets/catengar.rc"), .include_paths = &.{b.path("assets")} });
    const core_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    }) });
    core_tests.root_module.linkSystemLibrary("advapi32", .{});
    core_tests.root_module.linkSystemLibrary("winhttp", .{});
    b.step("test-core", "Test LCU parsing, selection and automation without a client").dependOn(&b.addRunArtifact(core_tests).step);
    const image_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/native_image_test.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    }) });
    image_tests.root_module.addImport("native_sdk", app.exe.root_module.import_table.get("native_sdk").?);
    b.step("test-images", "Check Native image cache invalidation").dependOn(&b.addRunArtifact(image_tests).step);
    const transport = b.addExecutable(.{ .name = "catengar-transport-test", .root_module = b.createModule(.{
        .root_source_file = b.path("src/transport_test.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    }) });
    transport.root_module.linkSystemLibrary("winhttp", .{});
    const transport_run = b.addRunArtifact(transport);
    if (b.args) |args| transport_run.addArgs(args);
    b.step("test-transport", "Loopback transport fault tests; invoke via scripts/test-transport.py").dependOn(&transport_run.step);
    const diag = b.addExecutable(.{ .name = "catengar-diagnose", .root_module = b.createModule(.{
        .root_source_file = b.path("src/diagnose.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    }) });
    diag.root_module.linkSystemLibrary("winhttp", .{});
    diag.root_module.addWin32ResourceFile(.{ .file = b.path("assets/catengar.rc"), .include_paths = &.{b.path("assets")} });
    b.installArtifact(diag);
    b.step("diagnose", "Read-only LCU connection and resource diagnostics").dependOn(&b.addRunArtifact(diag).step);
}
