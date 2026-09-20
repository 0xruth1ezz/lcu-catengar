const std = @import("std");
const discovery = @import("auth_discovery.zig");

// One bounded message; no commands, executable paths or arbitrary operations.
pub const size = 272;
pub const Status = enum(u8) { ready = 1, not_running = 2, admin_required = 3, failed = 4, client_starting = 5 };
pub const Result = struct { status: Status, credentials: discovery.Credentials = .{ .port = 0, .pid = 0, .token = .{} } };

pub fn encode(result: Result) [size]u8 {
    var bytes: [size]u8 = @splat(0);
    bytes[0..4].* = "CAH1".*;
    bytes[4] = @intFromEnum(result.status);
    if (result.status == .ready) {
        std.mem.writeInt(u16, bytes[6..8], result.credentials.port, .little);
        std.mem.writeInt(u32, bytes[8..12], result.credentials.pid, .little);
        const token = result.credentials.token.text();
        std.mem.writeInt(u16, bytes[12..14], @intCast(token.len), .little);
        @memcpy(bytes[14..][0..token.len], token);
    }
    return bytes;
}

pub fn decode(bytes: []const u8) !Result {
    if (bytes.len != size or !std.mem.eql(u8, bytes[0..4], "CAH1") or bytes[5] != 0) return error.InvalidAuthPacket;
    const status = std.enums.fromInt(Status, bytes[4]) orelse return error.InvalidAuthPacket;
    if (status != .ready) {
        for (bytes[6..]) |byte| if (byte != 0) return error.InvalidAuthPacket;
        return .{ .status = status };
    }
    const port = std.mem.readInt(u16, bytes[6..8], .little);
    const pid = std.mem.readInt(u32, bytes[8..12], .little);
    const len = std.mem.readInt(u16, bytes[12..14], .little);
    if (port == 0 or pid == 0 or len == 0 or len > 256) return error.InvalidAuthPacket;
    const token = bytes[14..][0..len];
    if (std.mem.indexOfAny(u8, token, "\r\n\x00") != null) return error.InvalidAuthPacket;
    for (bytes[14 + len ..]) |byte| if (byte != 0) return error.InvalidAuthPacket;
    return .{ .status = status, .credentials = .{ .port = port, .pid = pid, .token = @import("types.zig").Text(256).init(token) } };
}
