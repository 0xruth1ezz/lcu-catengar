const std = @import("std");
const t = @import("types.zig");
const logic = @import("logic.zig");
const Service = @import("service.zig").Service;
const settings = @import("settings.zig");
const a = std.testing.allocator;

// A/B/C are 107/99/22; 1 represents an unrelated champion.
const Client = struct {
    phase: []const u8 = "ChampSelect",
    phase_status: u32 = 200,
    game_id: i64 = 9000000001,
    current: i32 = 1,
    bench: []const i32 = &.{99},
    completed_action: bool = true,
    card: bool = false,
    write_status: u32 = 204,
    writes: usize = 0,
    last_champion: i32 = 0,
    pickable_reads: usize = 0,

    pub fn request(self: *Client, temp: std.mem.Allocator, method: []const u8, path: []const u8, body: []const u8) !@import("lcu.zig").Response {
        if (std.mem.eql(u8, method, "GET")) {
            if (std.mem.eql(u8, path, "/lol-gameflow/v1/gameflow-phase")) return .{ .status = self.phase_status, .body = try std.json.Stringify.valueAlloc(temp, self.phase, .{}) };
            if (std.mem.eql(u8, path, "/lol-gameflow/v1/session")) return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(temp, .{ .phase = self.phase, .gameData = .{ .gameId = self.game_id, .queue = .{ .id = 2400 } } }, .{}) };
            if (std.mem.eql(u8, path, "/lol-champ-select/v1/session")) return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(temp, .{
                .localPlayerCellId = 0,
                .myTeam = .{.{ .cellId = 0, .championId = self.current }},
                .benchEnabled = !self.card,
                .benchChampionIds = self.bench,
                .actions = .{.{.{ .id = 8, .actorCellId = 0, .type = "pick", .isInProgress = !self.completed_action, .completed = self.completed_action }}},
            }, .{}) };
            if (std.mem.eql(u8, path, "/lol-champ-select/v1/pickable-champion-ids")) {
                self.pickable_reads += 1;
                return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(temp, self.bench, .{}) };
            }
        }
        if (std.mem.eql(u8, method, "POST") and std.mem.startsWith(u8, path, "/lol-champ-select/v1/session/bench/swap/")) {
            self.last_champion = try std.fmt.parseInt(i32, path[std.mem.lastIndexOfScalar(u8, path, '/').? + 1 ..], 10);
        } else if (std.mem.eql(u8, method, "PATCH") and std.mem.eql(u8, path, "/lol-champ-select/v1/session/actions/8")) {
            const parsed = try std.json.parseFromSlice(std.json.Value, temp, body, .{});
            defer parsed.deinit();
            self.last_champion = logic.integer(logic.get(parsed.value, "championId"));
            try std.testing.expect(logic.yes(logic.get(parsed.value, "completed")));
        } else return error.UnexpectedRequest;
        self.writes += 1;
        return .{ .status = self.write_status, .body = try temp.dupe(u8, "") };
    }
};

const Harness = struct {
    service: *Service,
    state: *t.Snapshot,
    gate: logic.RetryGate = .{},
    accept: logic.RetryGate = .{},
    client: Client = .{},

    fn init(always: bool) !Harness {
        const service = try a.create(Service);
        errdefer a.destroy(service);
        service.* = .{};
        service.preferences = .{ .auto_pick = true, .always_prioritize = always };
        for ([_]i32{ 107, 99, 22 }) |id| service.preferences.add(id);
        const state = try a.create(t.Snapshot);
        state.* = .{};
        return .{ .service = service, .state = state };
    }
    fn deinit(self: *Harness) void {
        a.destroy(self.state);
        a.destroy(self.service);
    }
    fn tick(self: *Harness) !void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        try self.service.tick(arena.allocator(), &self.client, self.state, &self.gate, &self.accept);
    }
    fn confirmB(self: *Harness) !void {
        try self.tick();
        try std.testing.expectEqual(@as(i32, 99), self.client.last_champion);
        try std.testing.expect(!self.state.pick_completed);
        self.client.current = 99;
        self.client.bench = &.{};
        try self.tick();
        try std.testing.expect(self.state.pick_completed);
    }
};

test "priority policy defaults on for new and legacy settings and persists either value" {
    try std.testing.expect((t.Preferences{}).always_prioritize);
    const legacy = try settings.decode(a, "{\"auto_pick\":true,\"priority\":[107,99,22]}");
    try std.testing.expect(legacy.always_prioritize);
    for ([_]bool{ false, true }) |enabled| {
        var prefs = legacy;
        prefs.always_prioritize = enabled;
        const bytes = try settings.encode(a, &prefs);
        defer a.free(bytes);
        const restored = try settings.decode(a, bytes);
        try std.testing.expectEqualDeep(prefs, restored);
    }
}

test "continuous policy upgrades B to A after a completed selection and retains A" {
    var h = try Harness.init(true);
    defer h.deinit();
    try h.confirmB();
    h.client.bench = &.{ 22, 107 };
    try h.tick();
    try std.testing.expectEqual(@as(i32, 107), h.client.last_champion);
    try std.testing.expectEqual(@as(usize, 2), h.client.writes);
    h.client.current = 107;
    h.client.bench = &.{ 99, 22 };
    try h.tick();
    try h.tick();
    try std.testing.expectEqual(@as(usize, 2), h.client.writes);
}

test "continuous policy reevaluates after manual changes including unrelated champions" {
    var h = try Harness.init(true);
    defer h.deinit();
    for ([_]i32{ 1, 22, 99 }) |current| {
        h.client.current = current;
        h.client.bench = &.{ 99, 107, 22 };
        h.service.pending_pick = 0;
        h.gate = .{};
        try h.tick();
        try std.testing.expectEqual(@as(i32, 107), h.client.last_champion);
    }
    try std.testing.expectEqual(@as(usize, 3), h.client.writes);
}

test "one-shot policy stops on confirmed B even when A appears in the confirming snapshot" {
    var h = try Harness.init(false);
    defer h.deinit();
    try h.tick();
    try h.tick(); // A submitted request is still unconfirmed.
    try std.testing.expect(!h.state.pick_completed);
    h.client.current = 99;
    h.client.bench = &.{107};
    try h.tick();
    try std.testing.expect(h.state.pick_completed);
    h.client.current = 1; // Manual change must not restart the completed task.
    try h.tick();
    try std.testing.expectEqual(@as(usize, 1), h.client.writes);
    try std.testing.expectEqual(@as(usize, 1), h.state.swapped);
}

test "one-shot does not mistake manually held priority champions for automatic success" {
    var h = try Harness.init(false);
    defer h.deinit();
    h.client.current = 22;
    h.client.bench = &.{ 99, 107 };
    try h.tick();
    try std.testing.expectEqual(@as(i32, 107), h.client.last_champion);
    try std.testing.expect(!h.state.pick_completed);
}

test "failed and timed-out requests do not finish a one-shot task" {
    var h = try Harness.init(false);
    defer h.deinit();
    h.client.write_status = 409;
    try h.tick();
    try std.testing.expect(!h.state.pick_completed);
    try std.testing.expectEqual(@as(i32, 0), h.service.pending_pick);
    h.client.write_status = 204;
    h.gate = .{};
    try h.tick();
    h.service.pending_until = 0;
    h.gate = .{};
    try h.tick();
    try std.testing.expect(!h.state.pick_completed);
    try std.testing.expectEqual(@as(usize, 3), h.client.writes);
    h.client.current = 99;
    try h.tick();
    try std.testing.expect(h.state.pick_completed);
}

test "card selection obeys one-shot completion without querying further cards" {
    var h = try Harness.init(false);
    defer h.deinit();
    h.client.card = true;
    h.client.completed_action = false;
    h.client.current = 0;
    try h.confirmB();
    h.client.bench = &.{107};
    try h.tick();
    try std.testing.expectEqual(@as(usize, 1), h.client.writes);
    try std.testing.expectEqual(@as(usize, 1), h.client.pickable_reads);
}

test "one-shot completion survives reconnection preferences and master-switch changes" {
    var h = try Harness.init(false);
    defer h.deinit();
    try h.confirmB();
    h.state.connected = false;
    h.state.phase.set("未连接");
    h.client.current = 1;
    h.client.bench = &.{107};
    h.service.preferences.move(22, true);
    h.service.preferences.theme = .chatgpt_light;
    h.service.preferences.auto_pick = false;
    try h.tick();
    h.service.preferences.auto_pick = true;
    try h.tick();
    try std.testing.expect(h.state.pick_completed);
    try std.testing.expectEqual(@as(usize, 1), h.client.writes);
}

test "changing to continuous policy resumes a stopped round and switching back stops again" {
    var h = try Harness.init(false);
    defer h.deinit();
    try h.confirmB();
    h.client.bench = &.{107};
    h.service.preferences.always_prioritize = true;
    try h.tick();
    try std.testing.expectEqual(@as(usize, 2), h.client.writes);
    h.client.current = 107;
    h.service.preferences.always_prioritize = false;
    try h.tick();
    h.client.current = 1;
    h.gate = .{};
    try h.tick();
    try std.testing.expectEqual(@as(usize, 2), h.client.writes);
}

test "new round rearms one-shot after phase exit or a changed 64-bit game ID" {
    for ([_]bool{ false, true }) |missed_phase| {
        var h = try Harness.init(false);
        defer h.deinit();
        try h.confirmB();
        if (!missed_phase) {
            h.client.phase = "Lobby";
            try h.tick();
            try std.testing.expect(!h.state.pick_completed);
        }
        h.client.phase = "ChampSelect";
        h.client.game_id += 1;
        h.client.current = 1;
        h.client.bench = &.{ 22, 107, 99 };
        try h.tick();
        try std.testing.expectEqual(@as(usize, 2), h.client.writes);
        try std.testing.expectEqual(@as(i32, 107), h.client.last_champion);
        try std.testing.expect(!h.state.pick_completed);
    }
}

test "missing phase response cannot clear a completed one-shot round" {
    var h = try Harness.init(false);
    defer h.deinit();
    try h.confirmB();
    h.client.phase_status = 404;
    try std.testing.expectError(error.PhaseUnavailable, h.tick());
    h.client.phase_status = 200;
    h.client.phase = "";
    try std.testing.expectError(error.InvalidPhase, h.tick());
    h.client.phase = "ChampSelect";
    h.client.bench = &.{107};
    try h.tick();
    try std.testing.expect(h.state.pick_completed);
    try std.testing.expectEqual(@as(usize, 1), h.client.writes);
}
