const std = @import("std");
const t = @import("types.zig");
const logic = @import("logic.zig");

const filename = "priority-champions.json";
const ChampionWire = struct {
    id: i32,
    name: []const u8,
    alias: []const u8,
    asset: []const u8,
    // Relative to the data directory, so moving the profile preserves images.
    portrait: []const u8 = "",
};
const Wire = struct { version: u32 = 1, champions: []const ChampionWire };

pub const Cache = struct {
    champions: [t.max_priority]t.Champion = @splat(.{}),
    count: usize = 0,
    saved_hash: ?u64 = null,

    pub fn restore(self: *Cache, a: std.mem.Allocator, io: std.Io, root: []const u8, prefs: *const t.Preferences, state: *t.Snapshot) !void {
        const path = try std.fs.path.join(a, &.{ root, filename });
        defer a.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(128 * 1024)) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer a.free(bytes);
        const parsed = try std.json.parseFromSlice(Wire, a, bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        if (parsed.value.version != 1) return error.UnsupportedPriorityCache;
        self.count = 0;
        for (prefs.ids()) |id| {
            for (parsed.value.champions) |entry| {
                if (entry.id != id or !validChampion(entry)) continue;
                var champ: t.Champion = .{
                    .id = id,
                    .name = t.Text(96).init(entry.name),
                    .alias = t.Text(64).init(entry.alias),
                    .asset = t.Text(256).init(entry.asset),
                };
                if (validPortrait(entry.portrait)) {
                    const portrait = try std.fs.path.join(a, &.{ root, entry.portrait });
                    defer a.free(portrait);
                    if (portrait.len <= champ.icon_path.bytes.len) {
                        if (std.Io.Dir.cwd().access(io, portrait, .{})) |_| {
                            champ.icon_path.set(portrait);
                        } else |_| {}
                    }
                }
                self.champions[self.count] = champ;
                self.count += 1;
                break;
            }
        }
        @memcpy(state.champions[0..self.count], self.champions[0..self.count]);
        state.champion_count = self.count;
        state.icon_count = 0;
        for (self.champions[0..self.count]) |champ| {
            if (champ.icon_path.len > 0) state.icon_count += 1;
        }
        if (self.count > 0) state.catalog_generation = @import("catalog.zig").generation("offline-priority", self.champions[0..self.count]);
    }

    /// Keep older known data when a reconnect has not supplied this hero yet.
    /// New metadata and successfully downloaded portraits replace it separately.
    pub fn update(self: *Cache, prefs: *const t.Preferences, state: *const t.Snapshot) void {
        var next: [t.max_priority]t.Champion = @splat(.{});
        var count: usize = 0;
        for (prefs.ids()) |id| {
            var saved: ?t.Champion = null;
            for (self.champions[0..self.count]) |champ| {
                if (champ.id == id) {
                    saved = champ;
                    break;
                }
            }
            for (state.champions[0..state.champion_count]) |champ| {
                if (champ.id != id or champ.name.len == 0 or !logic.candidateChampion(champ.id, champ.alias.text())) continue;
                var current = champ;
                if (current.icon_path.len == 0) {
                    if (saved) |old| current.icon_path = old.icon_path;
                }
                saved = current;
                break;
            }
            if (saved) |champ| {
                next[count] = champ;
                count += 1;
            }
        }
        self.champions = next;
        self.count = count;
    }

    pub fn save(self: *Cache, a: std.mem.Allocator, io: std.Io, root: []const u8) !void {
        var fingerprint = std.hash.Wyhash.init(0);
        for (self.champions[0..self.count]) |*champ| {
            fingerprint.update(std.mem.asBytes(&champ.id));
            for ([_][]const u8{ champ.name.text(), champ.alias.text(), champ.asset.text(), champ.icon_path.text() }) |field| {
                fingerprint.update(std.mem.asBytes(&field.len));
                fingerprint.update(field);
            }
        }
        const hash = fingerprint.final();
        if (self.saved_hash == hash) return;
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const temp = arena.allocator();
        const cwd = try std.process.currentPathAlloc(io, temp);
        var entries: [t.max_priority]ChampionWire = undefined;
        for (self.champions[0..self.count], 0..) |*champ, i| {
            const relative = if (champ.icon_path.len > 0) try std.fs.path.relative(temp, cwd, null, root, champ.icon_path.text()) else "";
            entries[i] = .{
                .id = champ.id,
                .name = champ.name.text(),
                .alias = champ.alias.text(),
                .asset = champ.asset.text(),
                .portrait = if (validPortrait(relative)) relative else "",
            };
        }
        const bytes = try std.json.Stringify.valueAlloc(temp, Wire{ .champions = entries[0..self.count] }, .{ .whitespace = .indent_2 });
        const path = try std.fs.path.join(temp, &.{ root, filename });
        var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
        defer atomic.deinit(io);
        try atomic.file.writeStreamingAll(io, bytes);
        try atomic.replace(io);
        self.saved_hash = hash;
    }
};

fn validChampion(entry: ChampionWire) bool {
    return logic.candidateChampion(entry.id, entry.alias) and entry.name.len > 0 and entry.name.len <= 96 and entry.alias.len <= 64 and entry.asset.len <= 256 and
        std.unicode.utf8ValidateSlice(entry.name) and std.unicode.utf8ValidateSlice(entry.alias) and (entry.asset.len == 0 or logic.validAsset(entry.asset));
}

fn validPortrait(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfAny(u8, path, ":\x00") != null) return false;
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    if (!std.mem.eql(u8, parts.next() orelse return false, "cache")) return false;
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return false;
    }
    return std.mem.endsWith(u8, path, ".png");
}

/// Priorities get the first available download slot; a failed image backs off
/// independently so it cannot starve the remaining selected heroes.
pub const PortraitQueue = struct {
    ids: [t.max_priority]i32 = @splat(0),
    retry_at: [t.max_priority]u64 = @splat(0),

    pub fn next(self: *PortraitQueue, prefs: *const t.Preferences, state: *const t.Snapshot, now: u64) ?usize {
        for (prefs.ids(), 0..) |id, rank| {
            if (self.ids[rank] != id) {
                self.ids[rank] = id;
                self.retry_at[rank] = 0;
            }
            if (now < self.retry_at[rank]) continue;
            for (state.champions[0..state.champion_count], 0..) |champ, i| {
                if (champ.id == id and champ.icon_path.len == 0 and logic.validAsset(champ.asset.text())) {
                    self.retry_at[rank] = now + 5000;
                    return i;
                }
            }
        }
        return null;
    }
};
