const std = @import("std");
const broker = @import("auth_broker.zig");
const auth = @import("auth.zig");
const win = @import("windows.zig");
const c = win.c;
const expect = std.testing.expect;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const fixture = args[1];
    const elevated = args.len == 3 and std.mem.eql(u8, args[2], "--elevated");
    const wake = c.CreateEventW(null, 1, 0, null) orelse return error.EventFailed;
    defer _ = c.CloseHandle(wake);

    var client = try broker.Client.spawn(fixture, elevated, wake);
    var live = true;
    defer if (live) client.deinit();
    try std.testing.expectEqual(if (elevated) true else win.isAdmin(), try win.processIsElevated(client.process));
    try std.testing.expectError(error.HelperIdentity, client.server.verifyClient(c.GetCurrentProcess()));
    var identity: auth.Identity = .{};
    var recovery: auth.Recovery = .{};
    try expect((try client.read(wake)).status == .not_running);
    identity.update(.not_running, null);
    try expect(!recovery.available(identity, win.now()));
    try expect((try client.read(wake)).status == .client_starting);
    identity.update(.client_starting, null);
    try expect(!recovery.available(identity, win.now()));
    const first = try client.read(wake);
    try expect(first.status == .ready and first.credentials.port == 12345);
    identity.update(.ready, first.credentials);
    try expect(recovery.available(identity, win.now()));
    recovery.connected(identity);
    const refreshed = try client.read(wake);
    try expect(refreshed.status == .ready and refreshed.credentials.port == 12346);
    try std.testing.expectEqualStrings("fixture-refreshed", refreshed.credentials.token.text());
    identity.update(.ready, refreshed.credentials);
    try expect(recovery.changed(identity));
    const offline = try client.read(wake);
    try expect(offline.status == .not_running and offline.credentials.token.len == 0);
    identity.update(.not_running, null);
    try expect(!recovery.available(identity, win.now()));

    // An unrelated live process cannot claim ownership of our pipe.
    var impostor = try broker.Server.create();
    defer impostor.deinit();
    try std.testing.expectError(error.HelperIdentity, broker.Sender.connect(&impostor.nonce, c.GetProcessId(client.process), null));
    try std.testing.expectError(error.HelperParent, broker.Sender.connect(&impostor.nonce, c.GetCurrentProcessId(), "not-catengar.exe"));

    // Keep a process handle after closing IPC so we can check for orphan helpers.
    var process: c.HANDLE = null;
    try expect(c.DuplicateHandle(c.GetCurrentProcess(), client.process, c.GetCurrentProcess(), &process, c.SYNCHRONIZE, 0, 0) != 0);
    defer _ = c.CloseHandle(process);
    client.deinit();
    live = false;
    try expect(c.WaitForSingleObject(process, 3000) == c.WAIT_OBJECT_0);

    // Pending reads are cancelled and drained before their stack is released.
    var server = try broker.Server.create();
    defer server.deinit();
    var sender = try broker.Sender.connect(&server.nonce, c.GetCurrentProcessId(), null);
    defer sender.deinit();
    const current = c.OpenProcess(c.SYNCHRONIZE | c.PROCESS_QUERY_LIMITED_INFORMATION, 0, c.GetCurrentProcessId()) orelse return error.ProcessHandle;
    defer _ = c.CloseHandle(current);
    try server.accept(current, wake);
    _ = c.SetEvent(wake);
    const start = win.now();
    try std.testing.expectError(error.Interrupted, server.read(current, wake));
    try expect(win.now() - start < 1000);
    _ = c.ResetEvent(wake);
    try sender.write(.{ .status = .not_running });
    try expect((try server.read(current, wake)).status == .not_running);
    try std.testing.expectError(error.HelperMissing, broker.Client.spawn("C:\\catengar-nonexistent-fixture.exe", false, wake));
    std.debug.print("Credential helper: actual process elevation, IPC, token refresh, peer identities, pipe shutdown and cancellation passed.\n", .{});
}
