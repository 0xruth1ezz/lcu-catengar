const std = @import("std");
comptime {
    @import("portable_target.zig").requireBaseline();
}
const auth = @import("auth.zig");
const lcu = @import("lcu.zig");
const logic = @import("logic.zig");
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{ .environ = .{ .block = .global } });
    defer threaded.deinit();
    var creds = auth.discover(a, threaded.io()) catch |err| {
        std.debug.print("LCU discovery: {s}\n", .{@errorName(err)});
        if (err == error.AdminRequired) std.debug.print("Launch catengar.exe: only its credential helper will request administrator permission.\n", .{});
        return err;
    };
    defer @memset(std.mem.asBytes(&creds), 0);
    var client = try lcu.Client.init(creds);
    defer client.deinit();
    const stream = try @import("events.zig").Stream.create(&client);
    defer stream.destroy();
    try stream.cache.sync(a, &client, false);
    std.debug.print("WebSocket: upgraded and subscribed to {d} LCU resources\n", .{@import("events.zig").paths.len});
    for ([_][]const u8{ "/lol-gameflow/v1/gameflow-phase", "/lol-game-data/assets/v1/champion-summary.json", "/lol-perks/v1/perks", "/lol-perks/v1/styles" }) |endpoint| {
        const response = try client.request(a, "GET", endpoint, "");
        std.debug.print("{s}: HTTP {d}, {d} bytes\n", .{ endpoint, response.status, response.body.len });
        if (!response.ok()) continue;
        const parsed = try response.json(a);
        defer parsed.deinit();
        if (parsed.value == .string) std.debug.print("Phase: {s}\n", .{parsed.value.string});
        if (parsed.value == .array) std.debug.print("Entries: {d}\n", .{logic.items(parsed.value).len});
    }
    // Check that an idle stream survives longer than REST's receive timeout.
    @import("windows.zig").sleep(3000);
    std.debug.print("WebSocket received frames: {d}; resource events: {d}; error code: {d}\n", .{ stream.received.load(.acquire), stream.updates.load(.acquire), stream.failure.load(.acquire) });
    if (!stream.alive.load(.acquire)) {
        std.debug.print("Frame parse: {s}, bytes {d}, boundaries {x}/{x}\n", .{ stream.parse_error.text(), stream.invalid_length, stream.boundary[0], stream.boundary[1] });
        return error.WebSocketDisconnected;
    }
    std.debug.print("WebSocket: still connected; clean shutdown follows\n", .{});
}
