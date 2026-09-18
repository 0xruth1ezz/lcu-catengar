const std = @import("std");
const t = @import("types.zig");

/// Development-only input selected explicitly by -Dpreview-catalog. Paths
/// refer to local LCU-cached portraits; no fabricated resources ship.
pub fn load(a: std.mem.Allocator, io: std.Io, path: []const u8, snapshot: *t.Snapshot) !void {
    const Entry = struct { id: i32, name: []const u8, alias: []const u8, icon_path: []const u8 = "" };
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice([]Entry, a, bytes, .{});
    defer parsed.deinit();
    snapshot.* = .{};
    snapshot.catalog_generation = 1;
    snapshot.status.set("本地 LCU 缓存预览");
    for (parsed.value) |entry| {
        if (!@import("logic.zig").candidateChampion(entry.id, entry.alias) or snapshot.champion_count == t.max_champions) continue;
        snapshot.champions[snapshot.champion_count] = .{ .id = entry.id, .name = t.Text(96).init(entry.name), .alias = t.Text(64).init(entry.alias), .icon_path = t.Text(768).init(entry.icon_path) };
        snapshot.champion_count += 1;
        if (entry.icon_path.len > 0) snapshot.icon_count += 1;
    }
}
