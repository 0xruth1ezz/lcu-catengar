const std = @import("std");
const testing = std.testing;
const a = testing.allocator;
const events = @import("events.zig");
const lcu = @import("lcu.zig");
const logic = @import("logic.zig");
const Service = @import("service.zig").Service;
const t = @import("types.zig");

const pending = "{\"state\":\"InProgress\",\"playerResponse\":\"None\"}";
const accepted = "{\"state\":\"InProgress\",\"playerResponse\":\"Accepted\"}";

// Models a socket that remains connected while the LCU endpoints become ready
// later, without delivering any phase or ready-check events.
const Rest = struct {
    phase: []const u8 = "\"Lobby\"",
    phase_status: u32 = 200,
    ready: []const u8 = "null",
    ready_status: u32 = 404,
    phase_reads: usize = 0,
    ready_reads: usize = 0,
    accepts: usize = 0,
    racing_cache: ?*events.Cache = null,

    pub fn request(self: *@This(), allocator: std.mem.Allocator, method: []const u8, path: []const u8, body: []const u8) !lcu.Response {
        _ = allocator;
        _ = body;
        if (std.mem.eql(u8, method, "POST")) {
            try testing.expectEqualStrings("/lol-matchmaking/v1/ready-check/accept", path);
            try testing.expectEqualStrings("\"ReadyCheck\"", self.phase);
            try testing.expectEqual(@as(u32, 200), self.ready_status);
            try testing.expectEqualStrings(pending, self.ready);
            self.accepts += 1;
            return .{ .status = 204, .body = "" };
        }
        try testing.expectEqualStrings("GET", method);
        if (std.mem.eql(u8, path, events.paths[0])) {
            self.phase_reads += 1;
            return .{ .status = self.phase_status, .body = self.phase };
        }
        if (std.mem.eql(u8, path, events.paths[2])) {
            self.ready_reads += 1;
            if (self.racing_cache) |cache| {
                _ = try cache.apply(
                    \\[8,"OnJsonApiEvent_lol-matchmaking_v1_ready-check",{"uri":"/lol-matchmaking/v1/ready-check","eventType":"Update","data":{"state":"InProgress","playerResponse":"Accepted"}}]
                );
            }
            return .{ .status = self.ready_status, .body = self.ready };
        }
        try testing.expect(events.Cache.index(path) != null);
        return .{ .status = 404, .body = "null" };
    }
};

fn tick(service: *Service, rest: *Rest, cache: *events.Cache, state: *t.Snapshot, accept_gate: *logic.RetryGate) !void {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    var cached: events.CachedClientFor(Rest) = .{ .rest = rest, .cache = cache };
    var pick_gate: logic.RetryGate = .{};
    try service.tick(arena.allocator(), &cached, state, &pick_gate, accept_gate);
}

test "late LCU startup accepts with a silent socket and initially unavailable ready check" {
    const service = try a.create(Service);
    defer a.destroy(service);
    service.* = .{};
    // The switch is enabled before the client connects, as in the reported bug.
    service.configure(.{ .auto_accept = true });
    const state = try a.create(t.Snapshot);
    defer a.destroy(state);
    state.* = .{ .websocket = true };
    var cache: events.Cache = .{};
    defer cache.deinit();
    var rest: Rest = .{};
    var reconciler: events.Reconciler = .{};
    var gate: logic.RetryGate = .{};
    try cache.sync(a, &rest, false);
    try reconciler.update(a, &rest, &cache, true, 0);
    try tick(service, &rest, &cache, state, &gate);
    try testing.expect(state.connected);
    try testing.expect(service.preferences.auto_accept);

    rest.phase = "\"ReadyCheck\"";
    // No WS event: the old cache would stay in Lobby for up to 15 seconds.
    try testing.expect(cache.isPhase("Lobby"));
    try reconciler.update(a, &rest, &cache, true, 1000);
    try tick(service, &rest, &cache, state, &gate);
    try testing.expect(cache.isPhase("ReadyCheck"));
    try testing.expectEqual(@as(usize, 0), rest.accepts);

    // The first ready-check read returned 404; it becomes available without
    // another phase transition, so a one-time phase sync cannot recover it.
    rest.ready_status = 200;
    rest.ready = pending;
    const reads = rest.ready_reads;
    try reconciler.update(a, &rest, &cache, true, 1499);
    try testing.expectEqual(reads, rest.ready_reads);
    try reconciler.update(a, &rest, &cache, true, 1500);
    try tick(service, &rest, &cache, state, &gate);
    try testing.expectEqual(@as(usize, 1), rest.accepts);
    try testing.expectEqual(@as(usize, 1), state.accepted);

    // Repeated stale None responses must not duplicate a successful accept.
    try reconciler.update(a, &rest, &cache, true, 2000);
    try tick(service, &rest, &cache, state, &gate);
    try testing.expectEqual(@as(usize, 1), rest.accepts);

    rest.phase = "\"Matchmaking\"";
    try reconciler.update(a, &rest, &cache, true, 3000);
    try tick(service, &rest, &cache, state, &gate);
    rest.phase = "\"ReadyCheck\"";
    try reconciler.update(a, &rest, &cache, true, 4000);
    try tick(service, &rest, &cache, state, &gate);
    try testing.expectEqual(@as(usize, 2), rest.accepts);
}

test "enabling auto accept shortens the pending health interval and disabling blocks writes" {
    var cache: events.Cache = .{};
    defer cache.deinit();
    var rest: Rest = .{ .phase = "\"ReadyCheck\"", .ready_status = 200, .ready = pending };
    var reconciler: events.Reconciler = .{ .next_health = 15000 };
    try reconciler.update(a, &rest, &cache, false, 0);
    try testing.expectEqual(@as(usize, 0), rest.phase_reads);
    try reconciler.update(a, &rest, &cache, true, 100);
    try reconciler.update(a, &rest, &cache, true, 1099);
    try testing.expectEqual(@as(usize, 0), rest.phase_reads);
    try reconciler.update(a, &rest, &cache, true, 1100);
    try testing.expectEqual(@as(usize, 1), rest.phase_reads);
    try testing.expectEqual(@as(usize, 1), rest.ready_reads);
    try reconciler.update(a, &rest, &cache, false, 2100);
    try testing.expectEqual(@as(usize, 1), rest.ready_reads);
    try testing.expectEqual(@as(u64, 17100), reconciler.next_health);

    const service = try a.create(Service);
    defer a.destroy(service);
    service.* = .{};
    const state = try a.create(t.Snapshot);
    defer a.destroy(state);
    state.* = .{};
    var gate: logic.RetryGate = .{};
    try tick(service, &rest, &cache, state, &gate);
    try testing.expectEqual(@as(usize, 0), rest.accepts);
}

test "ready check event racing a fallback read wins over the REST response" {
    for ([_]u32{ 200, 404 }) |status| {
        var cache: events.Cache = .{};
        defer cache.deinit();
        var rest: Rest = .{ .phase = "\"ReadyCheck\"", .ready_status = status, .ready = pending, .racing_cache = &cache };
        var reconciler: events.Reconciler = .{};
        try reconciler.update(a, &rest, &cache, true, 0);
        const response = try cache.read(a, @intFromEnum(events.Slot.ready));
        defer a.free(response.body);
        try testing.expectEqual(@as(u32, 200), response.status);
        try testing.expectEqualStrings(accepted, response.body);
    }
}

test "fallback health and ready check authentication failures propagate for reconnect" {
    for ([_]u32{ 401, 403 }) |status| {
        for ([_]bool{ false, true }) |expire_phase| {
            var cache: events.Cache = .{};
            defer cache.deinit();
            var rest: Rest = .{
                .phase = "\"ReadyCheck\"",
                .phase_status = if (expire_phase) status else 200,
                .ready_status = if (expire_phase) 200 else status,
                .ready = pending,
            };
            var reconciler: events.Reconciler = .{};
            try testing.expectError(error.AuthenticationExpired, reconciler.update(a, &rest, &cache, true, 0));
            try testing.expectEqual(@as(usize, 0), rest.accepts);
        }
    }
}
