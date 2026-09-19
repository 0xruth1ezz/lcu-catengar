const std = @import("std");
const t = @import("types.zig");

/// Development-only input selected explicitly by -Dpreview-catalog. Paths
/// refer to local LCU-cached portraits; no fabricated resources ship.
pub fn load(a: std.mem.Allocator, io: std.Io, path: []const u8, snapshot: *t.Snapshot) !void {
    const Entry = struct { id: i32, name: []const u8, alias: []const u8, icon_path: []const u8 = "" };
    const Fixture = struct { champions: []Entry, profile: std.json.Value = .null, profile_icon_path: []const u8 = "", phase: []const u8 = "None" };
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
    defer a.free(bytes);
    const is_array = std.mem.startsWith(u8, std.mem.trim(u8, bytes, " \r\n\t"), "[");
    const legacy = if (is_array) try std.json.parseFromSlice([]Entry, a, bytes, .{}) else null;
    defer if (legacy) |parsed| parsed.deinit();
    const fixture = if (!is_array) try std.json.parseFromSlice(Fixture, a, bytes, .{}) else null;
    defer if (fixture) |parsed| parsed.deinit();
    snapshot.* = .{};
    snapshot.catalog_generation = 1;
    snapshot.status.set("本地 LCU 缓存预览");
    if (fixture) |parsed| {
        snapshot.profile = @import("profile.zig").parse(parsed.value.profile);
        snapshot.profile.icon_path.set(parsed.value.profile_icon_path);
        snapshot.connected = snapshot.profile.name.len > 0;
        if (snapshot.connected) snapshot.phase.set(parsed.value.phase);
    }
    for (if (legacy) |parsed| parsed.value else fixture.?.value.champions) |entry| {
        if (!@import("logic.zig").candidateChampion(entry.id, entry.alias) or snapshot.champion_count == t.max_champions) continue;
        snapshot.champions[snapshot.champion_count] = .{ .id = entry.id, .name = t.Text(96).init(entry.name), .alias = t.Text(64).init(entry.alias), .icon_path = t.Text(768).init(entry.icon_path) };
        snapshot.champion_count += 1;
        if (entry.icon_path.len > 0) snapshot.icon_count += 1;
    }
}
