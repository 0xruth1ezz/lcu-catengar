const std = @import("std");
const t = @import("types.zig");
const side = @import("team_side.zig");
const logic = @import("logic.zig");
const events = @import("events.zig");
const Service = @import("service.zig").Service;
const a = std.testing.allocator;

test "team side requires the actual local player including cell zero" {
    for ([_]struct { json: []const u8, expected: t.TeamSide }{
        .{ .json = "{\"localPlayerCellId\":0,\"myTeam\":[{\"cellId\":1,\"team\":2},{\"cellId\":0,\"team\":1}]}", .expected = .blue },
        .{ .json = "{\"localPlayerCellId\":9,\"myTeam\":[{\"cellId\":9,\"team\":2}]}", .expected = .red },
        .{ .json = "{\"myTeam\":[{\"cellId\":0,\"team\":1}]}", .expected = .unknown },
        .{ .json = "{\"localPlayerCellId\":-1,\"myTeam\":[{\"cellId\":-1,\"team\":1}]}", .expected = .unknown },
        .{ .json = "{\"localPlayerCellId\":0,\"myTeam\":[{\"team\":1}]}", .expected = .unknown },
        .{ .json = "{\"localPlayerCellId\":0,\"myTeam\":[{\"cellId\":0,\"team\":100}]}", .expected = .unknown },
        .{ .json = "{\"isSpectating\":true,\"localPlayerCellId\":0,\"myTeam\":[{\"cellId\":0,\"team\":1}]}", .expected = .unknown },
        .{ .json = "null", .expected = .unknown },
    }) |case| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, case.json, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(case.expected, side.ownSide(parsed.value));
    }
}

const Client = struct {
    phase: []const u8 = "ChampSelect",
    phase_status: u32 = 200,
    game_id: i64 = 9000000001,
    queue_id: i32 = 450,
    mode: []const u8 = "ARAM",
    team: i32 = 1,
    room: []const u8 = "selection-one",
    conversations: []const u8 = "[{\"id\":\"c1~selection-one@chat\",\"type\":\"championSelect\"}]",
    chat_status: u32 = 200,
    post_status: u32 = 200,
    post_error: ?anyerror = null,
    leave_on_discovery: bool = false,
    cache_on_discovery: ?*events.Cache = null,
    chat_reads: usize = 0,
    writes: usize = 0,
    picks: usize = 0,
    last_body: t.Text(256) = .{},
    last_path: t.Text(512) = .{},

    pub fn request(self: *Client, temp: std.mem.Allocator, method: []const u8, path: []const u8, body: []const u8) !@import("lcu.zig").Response {
        if (std.mem.eql(u8, method, "GET")) {
            if (std.mem.eql(u8, path, events.paths[0])) return .{ .status = self.phase_status, .body = try std.json.Stringify.valueAlloc(temp, self.phase, .{}) };
            if (std.mem.eql(u8, path, events.paths[1])) return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(temp, .{ .phase = self.phase, .gameData = .{ .gameId = self.game_id, .queue = .{ .id = self.queue_id, .gameMode = self.mode } } }, .{}) };
            if (std.mem.eql(u8, path, events.paths[3])) return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(temp, .{
                .localPlayerCellId = 0,
                .gameId = self.game_id,
                .myTeam = .{.{ .cellId = 0, .championId = 1, .team = self.team }},
                .chatDetails = .{ .multiUserChatId = self.room },
                .benchEnabled = true,
                .benchChampionIds = .{99},
            }, .{}) };
            if (std.mem.eql(u8, path, side.conversations_path)) {
                self.chat_reads += 1;
                if (self.leave_on_discovery) self.phase = "Lobby";
                if (self.cache_on_discovery) |cache| {
                    _ = try cache.apply("[8,\"OnJsonApiEvent\",{\"uri\":\"/lol-gameflow/v1/gameflow-phase\",\"eventType\":\"Update\",\"data\":\"Lobby\"}]");
                }
                return .{ .status = self.chat_status, .body = self.conversations };
            }
        }
        if (std.mem.eql(u8, method, "POST") and std.mem.startsWith(u8, path, side.conversations_path ++ "/")) {
            self.writes += 1;
            self.last_body.set(body);
            self.last_path.set(path);
            if (self.post_error) |err| return err;
            return .{ .status = self.post_status, .body = "{}" };
        }
        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/lol-champ-select/v1/session/bench/swap/99")) {
            self.picks += 1;
            try std.testing.expectEqual(@as(usize, 0), self.chat_reads);
            return .{ .status = 204, .body = "" };
        }
        return error.UnexpectedRequest;
    }
};

const Harness = struct {
    service: *Service,
    state: *t.Snapshot,
    client: Client = .{},
    gate: logic.RetryGate = .{},
    accept: logic.RetryGate = .{},

    fn init() !Harness {
        const service = try a.create(Service);
        errdefer a.destroy(service);
        service.* = .{};
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
    fn retry(self: *Harness) !void {
        self.service.side_notice.next_attempt = 0;
        try self.tick();
    }
};

test "side notice sends and toasts once with both automation switches off" {
    for ([_]i32{ 1, 2 }) |team| {
        var h = try Harness.init();
        defer h.deinit();
        h.client.team = team;
        try h.tick();
        const expected: t.TeamSide = if (team == 1) .blue else .red;
        try std.testing.expectEqual(expected, h.state.last_team_side);
        try std.testing.expectEqual(@as(usize, 1), h.client.writes);
        try std.testing.expectEqualStrings("/lol-chat/v1/conversations/c1~selection-one%40chat/messages", h.client.last_path.text());
        const body = try std.json.parseFromSlice(std.json.Value, a, h.client.last_body.text(), .{});
        defer body.deinit();
        try std.testing.expectEqualStrings(if (team == 1) "🟦 本局我方为蓝色方 - by (Catengar)" else "🟥 本局我方为红色方 - by (Catengar)", logic.str(logic.get(body.value, "body")));
        try std.testing.expect(logic.eql(logic.get(body.value, "type"), "chat"));
        var toast: @import("toasts.zig").State = .{};
        toast.observe(h.state, 0);
        try std.testing.expectEqualStrings(expected.title(), toast.messages[0].title.text());
        try std.testing.expectEqual(expected, toast.messages[0].side);
        toast.dismiss(10);
        h.state.connected = false;
        h.state.phase.set("未连接");
        h.service.preferences.theme = .chatgpt_light;
        try h.retry();
        try h.retry();
        toast.observe(h.state, 20);
        try std.testing.expectEqual(@as(usize, 1), h.client.writes);
        try std.testing.expectEqual(@as(usize, 1), h.client.chat_reads);
        try std.testing.expectEqual(@as(usize, 0), toast.count);
    }
}

test "delayed side and chat readiness retain the toast and never select lobby chat" {
    var h = try Harness.init();
    defer h.deinit();
    h.client.team = 0;
    try h.tick();
    try std.testing.expectEqual(@as(usize, 0), h.state.side_notices);
    h.client.team = 2;
    h.client.conversations = "[{\"id\":\"party\",\"type\":\"customGame\"}]";
    try h.tick();
    try std.testing.expectEqual(@as(usize, 1), h.state.side_notices);
    try std.testing.expectEqual(@as(usize, 0), h.client.writes);
    h.service.side_notice.next_attempt = std.math.maxInt(u64);
    try h.tick();
    try std.testing.expectEqual(@as(usize, 1), h.client.chat_reads);
    h.client.conversations = (Client{}).conversations;
    try h.retry();
    try std.testing.expectEqual(@as(usize, 1), h.client.writes);
    try std.testing.expectEqual(@as(usize, 1), h.state.side_notices);
}

test "new phase game ID or chat room rearms both notification destinations" {
    for (0..3) |boundary| {
        var h = try Harness.init();
        defer h.deinit();
        if (boundary == 2) h.client.game_id = 0;
        try h.tick();
        switch (boundary) {
            0 => {
                h.client.phase = "Lobby";
                try h.tick();
                h.client.phase = "ChampSelect";
            },
            1 => h.client.game_id += 1,
            else => {
                h.client.room = "selection-two";
                h.client.conversations = "[{\"id\":\"selection-two@chat\",\"type\":\"championSelect\"}]";
            },
        }
        try h.retry();
        try std.testing.expectEqual(@as(usize, 2), h.client.writes);
        try std.testing.expectEqual(@as(usize, 2), h.state.side_notices);
    }
}

test "missing phase cannot rearm an already announced round" {
    var h = try Harness.init();
    defer h.deinit();
    try h.tick();
    h.client.phase_status = 404;
    try std.testing.expectError(error.PhaseUnavailable, h.retry());
    h.client.phase_status = 200;
    try h.retry();
    try std.testing.expectEqual(@as(usize, 1), h.client.writes);
}

test "chat failures retry with a bound and uncertain delivery never duplicates" {
    var h = try Harness.init();
    defer h.deinit();
    h.client.chat_status = 503;
    try h.tick();
    try std.testing.expectEqual(@as(usize, 1), h.state.side_notices);
    h.client.chat_status = 200;
    h.client.post_status = 404;
    try h.retry();
    try std.testing.expect(!h.service.side_notice.finished);
    h.client.post_status = 200;
    try h.retry();
    try std.testing.expect(h.service.side_notice.finished);

    h.client.game_id += 1;
    h.client.post_error = error.HttpReceive;
    try h.retry();
    const writes = h.client.writes;
    h.client.post_error = null;
    h.state.connected = false;
    try h.retry();
    try std.testing.expectEqual(writes, h.client.writes);
    try std.testing.expectEqual(t.LogLevel.success, h.state.logs[0].level); // Connection recovered.

    h.client.game_id += 1;
    h.client.post_status = 503;
    for (0..8) |_| try h.retry();
    try std.testing.expectEqual(writes + 5, h.client.writes);
    try std.testing.expect(h.service.side_notice.finished);
}

test "chat authentication failures recover without losing the side notice" {
    for ([_]bool{ false, true }) |post| {
        var h = try Harness.init();
        defer h.deinit();
        if (post) h.client.post_status = 401 else h.client.chat_status = 403;
        try std.testing.expectError(error.AuthenticationExpired, h.tick());
        h.client.post_status = 200;
        h.client.chat_status = 200;
        try h.retry();
        try std.testing.expect(h.service.side_notice.finished);
        try std.testing.expectEqual(@as(usize, 1), h.state.side_notices);
    }
}

test "ranked side is independent of ARAM picking and Arena has no red blue notice" {
    var h = try Harness.init();
    defer h.deinit();
    h.client.queue_id = 420;
    h.client.mode = "CLASSIC";
    try h.tick();
    try std.testing.expectEqual(@as(?bool, false), h.state.pick_supported);
    try std.testing.expectEqual(@as(usize, 1), h.client.writes);
    h.client.game_id += 1;
    h.client.queue_id = 1700;
    h.client.mode = "CHERRY";
    try h.retry();
    try std.testing.expectEqual(@as(usize, 1), h.client.writes);
    try std.testing.expectEqual(@as(usize, 1), h.state.side_notices);
}

test "chat work follows champion selection and cannot stop a pick on chat failure" {
    var h = try Harness.init();
    defer h.deinit();
    h.service.preferences.auto_pick = true;
    h.service.preferences.add(99);
    h.client.chat_status = 503;
    try h.tick();
    try std.testing.expectEqual(@as(usize, 1), h.client.picks);
    try std.testing.expectEqual(@as(i32, 99), h.service.pending_pick);
}

test "leaving selection during chat discovery prevents sending in REST and WS modes" {
    for ([_]bool{ false, true }) |websocket| {
        var h = try Harness.init();
        defer h.deinit();
        if (!websocket) {
            h.client.leave_on_discovery = true;
            try h.tick();
        } else {
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const temp = arena.allocator();
            var cache: events.Cache = .{};
            defer cache.deinit();
            for ([_]events.Slot{ .phase, .game, .selection }) |slot| {
                try cache.refresh(temp, &h.client, slot);
            }
            h.client.cache_on_discovery = &cache;
            var client: events.CachedClientFor(Client) = .{ .rest = &h.client, .cache = &cache };
            try h.service.tick(temp, &client, h.state, &h.gate, &h.accept);
        }
        try std.testing.expectEqual(@as(usize, 1), h.client.chat_reads);
        try std.testing.expectEqual(@as(usize, 0), h.client.writes);
    }
}

test "chat discovery matches the active room and rejects old or ambiguous rooms" {
    var h = try Harness.init();
    defer h.deinit();
    h.client.conversations = "[{\"id\":\"old-room@chat\",\"type\":\"championSelect\"}]";
    try h.tick();
    try std.testing.expectEqual(@as(usize, 0), h.client.writes);
    h.client.conversations = "[{\"id\":\"old-room@chat\",\"type\":\"championSelect\"},{\"id\":\"selection-one@chat\",\"type\":\"championSelect\"}]";
    try h.retry();
    try std.testing.expectEqual(@as(usize, 1), h.client.writes);

    h.client.game_id += 1;
    h.client.room = "";
    try h.retry();
    try std.testing.expectEqual(@as(usize, 1), h.client.writes);
    h.client.conversations = "[{\"id\":\"room/with?reserved#bytes\",\"type\":\"championSelect\"}]";
    try h.retry();
    try std.testing.expectEqual(@as(usize, 2), h.client.writes);
    try std.testing.expectEqualStrings("/lol-chat/v1/conversations/room%2Fwith%3Freserved%23bytes/messages", h.client.last_path.text());
}

test "WebSocket selection readiness is repaired then chat succeeds through REST" {
    var h = try Harness.init();
    defer h.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var cache: events.Cache = .{};
    defer cache.deinit();
    try cache.refresh(temp, &h.client, .phase);
    var reconciler: events.Reconciler = .{};
    try reconciler.selection(temp, &h.client, &cache, true, 0);
    const revision = cache.version(@intFromEnum(events.Slot.selection));
    try reconciler.selection(temp, &h.client, &cache, true, 999);
    try std.testing.expectEqual(revision, cache.version(@intFromEnum(events.Slot.selection)));
    var client: events.CachedClientFor(Client) = .{ .rest = &h.client, .cache = &cache };
    try h.service.tick(temp, &client, h.state, &h.gate, &h.accept);
    try std.testing.expectEqual(@as(usize, 1), h.client.writes);
    try std.testing.expect(!h.service.side_notice.needs_selection_sync);
    try reconciler.selection(temp, &h.client, &cache, false, 1000);
    try std.testing.expectEqual(revision, cache.version(@intFromEnum(events.Slot.selection)));
}
