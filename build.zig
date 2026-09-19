const std = @import("std");
const native = @import("native_sdk");

pub fn build(b: *std.Build) void {
    const sdk = b.dependency("native_sdk", .{});
    const app = native.addAppArtifacts(b, sdk, .{ .name = "catengar" });
    b.getInstallStep().dependOn(&b.addInstallFile(sdk.path("third_party/webview2/LICENSE.txt"), "bin/WebView2-LICENSE.txt").step);
    const options = b.addOptions();
    const version_text = @import("app.zon").version;
    const version = std.SemanticVersion.parse(version_text) catch @panic("Invalid app.zon version");
    const version_label = if (version.patch == 0 and version.pre == null and version.build == null)
        b.fmt("v{d}.{d}", .{ version.major, version.minor })
    else
        b.fmt("v{s}", .{version_text});
    options.addOption([]const u8, "version_label", version_label);
    options.addOption([]const u8, "version", version_text);
    options.addOption([]const u8, "preview_catalog", b.option([]const u8, "preview-catalog", "Read-only UI preview using a local catalog fixture (no LCU connection or settings writes)") orelse "");
    app.exe.root_module.addOptions("catengar_options", options);
    app.exe.root_module.linkSystemLibrary("winhttp", .{});
    app.exe.root_module.linkSystemLibrary("dwmapi", .{});
    app.exe.root_module.linkSystemLibrary("bcrypt", .{});
    app.exe.win32_manifest = b.path("assets/catengar.manifest");
    app.exe.root_module.addAnonymousImport("catengar_icon", .{ .root_source_file = b.path("assets/catengar.ico") });
    app.exe.root_module.addWin32ResourceFile(.{ .file = b.path("assets/catengar.rc"), .include_paths = &.{b.path("assets")} });
    const helper = b.addExecutable(.{ .name = "catengar-auth", .win32_manifest = b.path("assets/catengar-auth.manifest"), .root_module = b.createModule(.{
        .root_source_file = b.path("src/auth_helper.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    }) });
    helper.subsystem = .Windows;
    helper.root_module.linkSystemLibrary("shell32", .{});
    helper.root_module.linkSystemLibrary("advapi32", .{});
    helper.root_module.addWin32ResourceFile(.{ .file = b.path("assets/catengar-auth.rc"), .include_paths = &.{b.path("assets")} });
    b.installArtifact(helper);
    const fixture = b.addExecutable(.{ .name = "catengar-auth-fixture", .root_module = b.createModule(.{
        .root_source_file = b.path("src/auth_fixture.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    }) });
    const auth_tests = b.addExecutable(.{ .name = "catengar-auth-test", .root_module = b.createModule(.{
        .root_source_file = b.path("src/auth_broker_test.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    }) });
    for ([_][]const u8{ "shell32", "advapi32", "bcrypt", "ole32" }) |lib| auth_tests.root_module.linkSystemLibrary(lib, .{});
    const auth_run = b.addRunArtifact(auth_tests);
    auth_run.addArtifactArg(fixture);
    b.step("test-auth", "Test credential IPC, identity validation, refresh and helper lifecycle without UAC/LCU").dependOn(&auth_run.step);
    const core_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    }) });
    core_tests.root_module.linkSystemLibrary("advapi32", .{});
    core_tests.root_module.linkSystemLibrary("winhttp", .{});
    core_tests.root_module.linkSystemLibrary("shell32", .{});
    core_tests.root_module.linkSystemLibrary("ole32", .{});
    b.step("test-core", "Test LCU parsing, selection and automation without a client").dependOn(&b.addRunArtifact(core_tests).step);
    const image_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/native_image_test.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    }) });
    image_tests.root_module.addImport("native_sdk", app.exe.root_module.import_table.get("native_sdk").?);
    b.step("test-images", "Check Native image cache invalidation").dependOn(&b.addRunArtifact(image_tests).step);
    const ime_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/ime.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    }) });
    ime_tests.root_module.addImport("native_sdk", app.exe.root_module.import_table.get("native_sdk").?);
    b.step("test-ime", "Check input method focus and DPI positioning").dependOn(&b.addRunArtifact(ime_tests).step);
    const window_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/window_state.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    }) });
    window_tests.root_module.linkSystemLibrary("comctl32", .{});
    b.step("test-window", "Check persistent window placement").dependOn(&b.addRunArtifact(window_tests).step);
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
