// Offline fixture only. Never installed or included in release artifacts.
const std = @import("std");
const broker = @import("auth_broker.zig");
const c = @import("windows.zig").c;
const Text = @import("types.zig").Text;

pub fn main(init: std.process.Init) void {
    run(init) catch {};
}

fn run(init: std.process.Init) !void {
    const args = try broker.arguments(try init.minimal.args.toSlice(init.arena.allocator()));
    var sender = try broker.Sender.connect(args.nonce, args.parent, null);
    defer sender.deinit();
    try sender.write(.{ .status = .ready, .credentials = .{ .port = 12345, .pid = 100, .token = Text(256).init("fixture-first") } });
    try sender.write(.{ .status = .ready, .credentials = .{ .port = 12346, .pid = 101, .token = Text(256).init("fixture-refreshed") } });
    try sender.write(.{ .status = .not_running });
    while (c.WaitForSingleObject(sender.parent, 100) == c.WAIT_TIMEOUT) try sender.write(.{ .status = .not_running });
}
