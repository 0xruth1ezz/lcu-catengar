const std = @import("std");

pub fn candidateChampion(id: i32, alias: []const u8) bool {
    return id > 0 and !std.ascii.startsWithIgnoreCase(alias, "jade_");
}
const types = @import("types.zig");
pub const Value = std.json.Value;
pub fn get(v: Value, key: []const u8) Value {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
pub fn integer(v: Value) i32 {
    return if (v == .integer) std.math.cast(i32, v.integer) orelse 0 else 0;
}
pub fn str(v: Value) []const u8 {
    return if (v == .string) v.string else "";
}
pub fn yes(v: Value) bool {
    return v == .bool and v.bool;
}
pub fn items(v: Value) []const Value {
    return if (v == .array) v.array.items else &.{};
}
pub fn eql(v: Value, text: []const u8) bool {
    return std.mem.eql(u8, str(v), text);
}

pub fn isAram(queue_id: i32, mode: []const u8) bool {
    // Known queues plus the explicit LCU gameMode for rotated/custom ARAM queues.
    return queue_id == 450 or queue_id == 2400 or std.mem.eql(u8, mode, "ARAM") or std.mem.eql(u8, mode, "ARAM_MAYHEM");
}
pub const Selection = struct { champion: i32, action: ?i32 = null, legacy: bool = true };

pub fn ownChampion(session: Value) i32 {
    const local = get(session, "localPlayerCellId");
    if (local != .integer or local.integer < 0) return 0;
    for (items(get(session, "myTeam"))) |player| {
        if (integer(get(player, "cellId")) == local.integer) return integer(get(player, "championId"));
    }
    return 0;
}
pub fn benchIds(session: Value, out: []i32) usize {
    var n: usize = 0;
    const newer = get(session, "benchChampions");
    const list = if (newer == .array) items(newer) else items(get(session, "benchChampionIds"));
    for (list) |entry| {
        const id = integer(if (entry == .object) get(entry, "championId") else entry);
        if (id <= 0 or n == out.len) continue;
        // Newer clients explicitly mark unavailable/reserved bench entries.
        if (get(entry, "isAvailable") == .bool and !yes(get(entry, "isAvailable"))) continue;
        out[n] = id;
        n += 1;
    }
    return n;
}
pub fn choose(prefs: *const types.Preferences, queue_id: i32, mode: []const u8, session: Value, pickable: []const i32) ?Selection {
    if (!prefs.auto_pick or !isAram(queue_id, mode) or yes(get(session, "isSpectating"))) return null;
    const local = get(session, "localPlayerCellId");
    if (local != .integer or local.integer < 0) return null;
    const current = ownChampion(session);
    var pool: [64]i32 = undefined;
    const n = if (yes(get(session, "benchEnabled"))) benchIds(session, &pool) else 0;
    const legacy_field = get(session, "isLegacyChampSelect");
    const legacy = legacy_field != .bool or legacy_field.bool;
    for (prefs.ids()[0..@min(prefs.rank(current), prefs.count)]) |id| {
        for (pool[0..n]) |available| {
            if (id == available and current > 0) return .{ .champion = id, .legacy = legacy };
        }
        // Card-based ARAM: only our active, unfinished pick and the API's pickable list.
        if (std.mem.indexOfScalar(i32, pickable, id) != null) {
            for (items(get(session, "actions"))) |group| for (items(group)) |action| {
                if (eql(get(action, "type"), "pick") and integer(get(action, "actorCellId")) == local.integer and yes(get(action, "isInProgress")) and !yes(get(action, "completed"))) {
                    const action_id = get(action, "id");
                    if (action_id == .integer) return .{ .champion = id, .action = integer(action_id), .legacy = legacy };
                }
            };
        }
    }
    return null;
}
pub fn shouldAccept(enabled: bool, phase: []const u8, ready: Value) bool {
    return enabled and std.mem.eql(u8, phase, "ReadyCheck") and eql(get(ready, "state"), "InProgress") and eql(get(ready, "playerResponse"), "None");
}
pub fn validAsset(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/lol-game-data/assets/") and std.mem.indexOf(u8, path, "..") == null and std.mem.indexOfAny(u8, path, "\\:%?#\r\n") == null;
}

pub const RetryGate = struct {
    target: i32 = 0,
    next_ms: u64 = 0,
    attempts: u8 = 0,
    pub fn allowed(self: *RetryGate, id: i32, now: u64) bool {
        if (id != self.target) self.* = .{ .target = id };
        return now >= self.next_ms;
    }
    pub fn record(self: *RetryGate, now: u64, success: bool) void {
        self.attempts = if (success) 0 else @min(self.attempts +| 1, 5);
        self.next_ms = now + if (success) @as(u64, 1000) else @min(@as(u64, 250) << @intCast(self.attempts), 4000);
    }
};
