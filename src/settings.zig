const std = @import("std");
const types = @import("types.zig");
const Wire = struct { version: u32 = 1, theme: []const u8 = "chatgpt_dark", auto_accept: bool = false, auto_pick: bool = false, priority: []const i32 = &.{} };
pub fn decode(a: std.mem.Allocator, bytes: []const u8) !types.Preferences {
    const p = try std.json.parseFromSlice(Wire, a, bytes, .{ .ignore_unknown_fields = true });
    defer p.deinit();
    if (p.value.version != 1) return error.UnsupportedSettingsVersion;
    var prefs: types.Preferences = .{ .theme = @import("theme.zig").Preset.fromName(p.value.theme), .auto_accept = p.value.auto_accept, .auto_pick = p.value.auto_pick };
    for (p.value.priority) |id| prefs.add(id);
    return prefs;
}
pub fn encode(a: std.mem.Allocator, prefs: *const types.Preferences) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, Wire{ .theme = @tagName(prefs.theme), .auto_accept = prefs.auto_accept, .auto_pick = prefs.auto_pick, .priority = prefs.ids() }, .{ .whitespace = .indent_2 });
}
pub fn save(a: std.mem.Allocator, io: std.Io, path: []const u8, prefs: *const types.Preferences) !void {
    const bytes = try encode(a, prefs);
    defer a.free(bytes);
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.replace(io);
}
