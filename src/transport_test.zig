const std = @import("std");
const auth = @import("auth.zig");
const lcu = @import("lcu.zig");
const events = @import("events.zig");
const win = @import("windows.zig");
const t = @import("types.zig");

fn expect(ok: bool) !void {
    if (!ok) return error.TransportAssertionFailed;
}

/// Only invoked by scripts/test-transport.py with its private loopback fixtures.
/// This executable never discovers or connects to the real League client.
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.ExpectedTwoFixturePorts;
    var credentials: auth.Credentials = .{
        .pid = 1,
        .port = try std.fmt.parseInt(u16, args[1], 10),
        .token = t.Text(256).init("fixture-one"),
    };
    // Reject expired credentials consistently in REST and during WS upgrade.
    var bad = credentials;
    bad.token.set("invalid-fixture");
    var rejected = try lcu.Client.init(bad);
    defer rejected.deinit();
    if (rejected.request(a, "GET", events.paths[0], "")) |_| return error.ExpectedUnauthorized else |err| try expect(err == error.AuthenticationExpired);
    try expect(rejected.auth_expired);
    if (rejected.request(a, "POST", "/must-not-be-sent", "")) |_| return error.ExpectedUnauthorized else |err| try expect(err == error.AuthenticationExpired);
    var rejected_ws = try lcu.Client.init(bad);
    defer rejected_ws.deinit();
    if (events.Stream.create(&rejected_ws)) |s| {
        s.destroy();
        return error.ExpectedUnauthorized;
    } else |err| try expect(err == error.AuthenticationExpired);
    try expect(rejected_ws.auth_expired);

    var client = try lcu.Client.init(credentials);
    defer client.deinit();
    // Server sends events then stays idle indefinitely, without a close reply.
    // Repeat cancellation to exercise pending async I/O and callback lifetimes.
    for (0..8) |_| {
        const stream = try events.Stream.create(&client);
        try stream.cache.sync(a, &client, false);
        const until = win.now() + 3000;
        while (stream.updates.load(.acquire) == 0 and win.now() < until) stream.wait(50);
        const updated = stream.updates.load(.acquire) > 0;
        win.sleep(50);
        const before = win.now();
        stream.destroy();
        try expect(updated and win.now() - before < 1500);
    }
    std.debug.print("PASS: TLS authentication, WAMP subscription, repeated idle receive cancellation\n", .{});

    const dropped = try events.Stream.create(&client);
    _ = try client.request(a, "GET", "/fixture/drop", "");
    const until = win.now() + 3000;
    while (dropped.alive.load(.acquire) and win.now() < until) dropped.wait(50);
    const detected = !dropped.alive.load(.acquire);
    const invalidated = try dropped.cache.read(a, 0);
    dropped.destroy();
    try expect(detected and invalidated.status == 404);
    std.debug.print("PASS: remote disconnect detection and cache invalidation\n", .{});

    const old = try events.Stream.create(&client);
    try old.cache.sync(a, &client, false);
    var identity: auth.Identity = .{};
    identity.update(.ready, credentials);
    var recovery: auth.Recovery = .{};
    recovery.connected(identity);
    _ = try client.request(a, "GET", "/fixture/rotate", "");
    if (old.cache.health(a, &client)) |_| return error.ExpectedUnauthorized else |err| try expect(err == error.AuthenticationExpired);
    recovery.failed(identity, win.now());
    try expect(!recovery.available(identity, win.now() + 1000));
    old.destroy();
    credentials.token.set("fixture-two");
    identity.update(.ready, credentials);
    try expect(recovery.available(identity, win.now() + 1000));
    var refreshed = try lcu.Client.init(credentials);
    defer refreshed.deinit();
    const restored = try events.Stream.create(&refreshed);
    defer restored.destroy();
    try restored.cache.sync(a, &refreshed, false);
    try expect(restored.alive.load(.acquire));
    const phase = try restored.cache.read(a, 0);
    try expect(phase.ok() and std.mem.eql(u8, phase.body, "\"Lobby\""));
    recovery.connected(identity);
    credentials.port = try std.fmt.parseInt(u16, args[2], 10);
    credentials.pid = 2;
    credentials.token.set("fixture-one");
    identity.update(.ready, credentials);
    try expect(recovery.changed(identity));
    var restarted = try lcu.Client.init(credentials);
    defer restarted.deinit();
    const replacement = try events.Stream.create(&restarted);
    defer replacement.destroy();
    try replacement.cache.sync(a, &restarted, false);
    try expect(replacement.alive.load(.acquire));
    std.debug.print("PASS: token rotation while WS remains open, reauthentication, port/PID replacement and resubscription\n", .{});
}
