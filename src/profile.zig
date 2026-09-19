const std = @import("std");
const t = @import("types.zig");
const logic = @import("logic.zig");
const lcu = @import("lcu.zig");

pub const endpoint = "/lol-summoner/v1/current-summoner";

fn validPart(value: []const u8, capacity: usize) bool {
    if (value.len == 0 or value.len > capacity or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f or byte == '#') return false;
    return std.mem.trim(u8, value, " ").len != 0;
}

pub fn parse(value: std.json.Value) t.Profile {
    var profile: t.Profile = .{};
    const game_name = logic.str(logic.get(value, "gameName"));
    const display_name = logic.str(logic.get(value, "displayName"));
    const tag = logic.str(logic.get(value, "tagLine"));
    const name = if (validPart(game_name, 96)) game_name else display_name;
    if (!validPart(name, 96)) return profile;
    profile.name.set(name);
    // Never substitute summonerId/PUUID or truncate a copyable friend ID.
    if (validPart(game_name, 96) and validPart(tag, 31) and game_name.len + 1 + tag.len <= 128) {
        var buffer: [128]u8 = undefined;
        profile.riot_id.set(std.fmt.bufPrint(&buffer, "{s}#{s}", .{ game_name, tag }) catch unreachable);
    }
    const icon = logic.get(value, "profileIconId");
    if (icon == .integer and icon.integer >= 0 and icon.integer <= std.math.maxInt(u32)) profile.icon_id = @intCast(icon.integer);
    return profile;
}

pub fn refresh(a: std.mem.Allocator, client: anytype, profile: *t.Profile) !void {
    errdefer profile.* = .{};
    const response = try lcu.requestAuthenticated(client, a, "GET", endpoint, "");
    if (!response.ok()) {
        profile.* = .{};
        return;
    }
    const json = try response.json(a);
    defer json.deinit();
    var next = parse(json.value);
    if (next.icon_id != null and next.icon_id == profile.icon_id) next.icon_path = profile.icon_path;
    profile.* = next;
}

pub fn visible(s: *const t.Snapshot) bool {
    return s.connected and s.profile.name.len > 0;
}

pub fn cacheIcon(a: std.mem.Allocator, io: std.Io, client: anytype, root: []const u8, profile: *t.Profile) !void {
    const id = profile.icon_id orelse return;
    if (profile.icon_path.len > 0) return;
    const dir = try std.fs.path.join(a, &.{ root, "cache", "profile-icons" });
    const path = try std.fs.path.join(a, &.{ dir, try std.fmt.allocPrint(a, "{d}.jpg", .{id}) });
    if (path.len > 768) return error.PathTooLong;
    if (std.Io.Dir.cwd().access(io, path, .{})) |_| {
        profile.icon_path.set(path);
        return;
    } else |_| {}
    const asset = try std.fmt.allocPrint(a, "/lol-game-data/assets/v1/profile-icons/{d}.jpg", .{id});
    const response = try lcu.requestAuthenticated(client, a, "GET", asset, "");
    const bytes = response.body;
    const is_image = std.mem.startsWith(u8, bytes, "\xff\xd8\xff") or std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n");
    if (!response.ok() or !is_image or bytes.len > 2 * 1024 * 1024) return error.ImageUnavailable;
    try std.Io.Dir.cwd().createDirPath(io, dir);
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.replace(io);
    profile.icon_path.set(path);
}
