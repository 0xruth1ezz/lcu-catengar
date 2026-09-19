const std = @import("std");
comptime {
    @import("portable_target.zig").requireBaseline();
}
const win = @import("windows.zig");
const c = win.c;
const discovery = @import("auth_discovery.zig");
const broker = @import("auth_broker.zig");
const wire = @import("auth_protocol.zig");

pub fn main(init: std.process.Init) void {
    // No console/log file, even on malformed invocation or discovery failure.
    serve(init) catch {};
}

fn serve(init: std.process.Init) !void {
    if (!win.isAdmin()) return error.AdminRequired;
    const args = try broker.arguments(try init.minimal.args.toSlice(init.arena.allocator()));
    var sender = try broker.Sender.connect(args.nonce, args.parent, "catengar.exe");
    defer sender.deinit();
    while (c.WaitForSingleObject(sender.parent, 0) == c.WAIT_TIMEOUT) {
        var result: wire.Result = .{ .status = .failed };
        defer @memset(std.mem.asBytes(&result), 0);
        if (discovery.discover(std.heap.page_allocator, init.io)) |credentials| {
            result = .{ .status = .ready, .credentials = credentials };
        } else |err| {
            result.status = switch (err) {
                error.ClientNotRunning => .not_running,
                error.AdminRequired => .admin_required,
                else => .failed,
            };
        }
        try sender.write(result);
        const process = if (result.status == .ready) c.OpenProcess(c.SYNCHRONIZE, 0, result.credentials.pid) else null;
        defer if (process != null) {
            _ = c.CloseHandle(process);
        };
        if (process != null) {
            const handles = [_]c.HANDLE{ sender.parent, process };
            const reason = c.WaitForMultipleObjects(handles.len, &handles, 0, 5000);
            if (reason == c.WAIT_OBJECT_0) break;
            if (reason == c.WAIT_OBJECT_0 + 1) try sender.write(.{ .status = .not_running });
        } else if (c.WaitForSingleObject(sender.parent, 3000) == c.WAIT_OBJECT_0) break;
    }
}
