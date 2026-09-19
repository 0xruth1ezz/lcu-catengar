const std = @import("std");
const t = @import("types.zig");

pub const State = struct {
    id: i32 = 0,
    name: t.Text(96) = .{},
    url: t.Text(96) = .{},
    open: bool = false,
    web_ready: bool = false,
    web_error: bool = false,
    link_error: bool = false,
    return_focus: i32 = 0,
    reload: u64 = 0,

    pub fn begin(self: *State, id: i32, name: []const u8) void {
        self.* = .{ .id = id, .open = true };
        self.name.set(name);
        var url_buffer: [96]u8 = undefined;
        self.url.set(std.fmt.bufPrint(&url_buffer, "https://haidou.pro/champion/{d}/", .{id}) catch "");
    }
};
