//! Load an installed Windows CJK face. Native SDK takes a single SFNT face,
//! whereas Microsoft YaHei is a collection; extract in memory, never redistribute.
const std = @import("std");
const win = @import("windows.zig");
fn u16be(bytes: []const u8, at: usize) !u16 {
    if (at > bytes.len or bytes.len - at < 2) return error.InvalidFont;
    return std.mem.readInt(u16, bytes[at..][0..2], .big);
}
fn u32be(bytes: []const u8, at: usize) !u32 {
    if (at > bytes.len or bytes.len - at < 4) return error.InvalidFont;
    return std.mem.readInt(u32, bytes[at..][0..4], .big);
}
pub fn extract(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (bytes.len < 12) return error.InvalidFont;
    if (!std.mem.eql(u8, bytes[0..4], "ttcf")) return a.dupe(u8, bytes);
    if (try u32be(bytes, 8) == 0) return error.InvalidFont;
    const face: usize = try u32be(bytes, 12);
    const count: usize = try u16be(bytes, face + 4);
    if (count == 0 or count > 256) return error.InvalidFont;
    const header = 12 + 16 * count;
    if (face > bytes.len or header > bytes.len - face) return error.InvalidFont;
    var total: usize = header;
    for (0..count) |i| total += std.mem.alignForward(usize, try u32be(bytes, face + 12 + 16 * i + 12), 4);
    if (total > 24 * 1024 * 1024) return error.InvalidFont;
    const out = try a.alloc(u8, total);
    errdefer a.free(out);
    @memset(out, 0);
    @memcpy(out[0..header], bytes[face..][0..header]);
    var cursor = header;
    var head: ?usize = null;
    for (0..count) |i| {
        const record = 12 + 16 * i;
        const offset: usize = try u32be(bytes, face + record + 8);
        const len: usize = try u32be(bytes, face + record + 12);
        if (offset > bytes.len or len > bytes.len - offset) return error.InvalidFont;
        @memcpy(out[cursor..][0..len], bytes[offset..][0..len]);
        std.mem.writeInt(u32, out[record + 8 ..][0..4], @intCast(cursor), .big);
        if (std.mem.eql(u8, out[record..][0..4], "head") and len >= 12) {
            head = cursor;
            @memset(out[cursor + 8 ..][0..4], 0);
        }
        cursor += std.mem.alignForward(usize, len, 4);
    }
    if (head) |offset| {
        var checksum: u32 = 0;
        var i: usize = 0;
        while (i < out.len) : (i += 4) checksum +%= try u32be(out, i);
        std.mem.writeInt(u32, out[offset + 8 ..][0..4], 0xB1B0AFBA -% checksum, .big);
    }
    return out;
}
pub fn load(a: std.mem.Allocator, io: std.Io) ![]u8 {
    var windows: [32768]u16 = undefined;
    const n = win.c.GetWindowsDirectoryW(&windows, windows.len);
    if (n == 0 or n >= windows.len) return error.FontUnavailable;
    const root = try std.unicode.utf16LeToUtf8Alloc(a, windows[0..n]);
    defer a.free(root);
    for ([_][]const u8{ "msyh.ttc", "msyhl.ttc", "simhei.ttf" }) |name| {
        const path = try std.fs.path.join(a, &.{ root, "Fonts", name });
        defer a.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(32 * 1024 * 1024)) catch continue;
        defer a.free(bytes);
        return extract(a, bytes) catch continue;
    }
    return error.FontUnavailable;
}
