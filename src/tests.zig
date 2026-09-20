const std = @import("std");

test {
    _ = @import("journal_tests.zig");
    _ = @import("selection_policy_tests.zig");
    _ = @import("auto_accept_tests.zig");
    _ = @import("priority_cache_tests.zig");
}

test "cancelled helper launches stay quiet until the user explicitly retries" {
    var prompt: @import("auth.zig").PromptGate = .{};
    try std.testing.expect(prompt.begin(0));
    prompt.failed(error.HelperCancelled, 0);
    for (0..100) |i| try std.testing.expect(!prompt.begin(i * 10000));
    prompt.retry();
    try std.testing.expect(prompt.begin(0));
    try std.testing.expect(!prompt.begin(1));
}

test "helper launch and IPC failures retry automatically without assuming UAC was denied" {
    for ([_]anyerror{ error.HelperLaunch, error.HelperMissing, error.HelperPipe, error.HelperTimeout, error.HelperExited }) |err| {
        var prompt: @import("auth.zig").PromptGate = .{};
        try std.testing.expect(prompt.begin(0));
        prompt.failed(err, 100);
        try std.testing.expect(!prompt.begin(5099));
        try std.testing.expect(prompt.begin(5100));
    }
}

test "credential packets round trip and offline messages carry no token" {
    const wire = @import("auth_protocol.zig");
    const credentials: @import("auth.zig").Credentials = .{ .port = 54321, .pid = 42, .token = @import("types.zig").Text(256).init("offline-fixture-token") };
    const ready = wire.encode(.{ .status = .ready, .credentials = credentials });
    try std.testing.expectEqualDeep(credentials, (try wire.decode(&ready)).credentials);
    for ([_]wire.Status{ .not_running, .client_starting, .admin_required, .failed }) |status| {
        const bytes = wire.encode(.{ .status = status, .credentials = credentials });
        const result = try wire.decode(&bytes);
        try std.testing.expectEqual(status, result.status);
        try std.testing.expectEqual(@as(usize, 0), result.credentials.token.len);
        for (bytes[6..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "credential IPC rejects malformed and oversized messages" {
    const wire = @import("auth_protocol.zig");
    const good = wire.encode(.{ .status = .ready, .credentials = .{ .port = 54321, .pid = 42, .token = @import("types.zig").Text(256).init("test") } });
    try std.testing.expectError(error.InvalidAuthPacket, wire.decode(good[0..20]));
    const long = good ++ [_]u8{0};
    try std.testing.expectError(error.InvalidAuthPacket, wire.decode(&long));
    for ([_]usize{ 0, 4, 5, 12, 13, 271 }) |index| {
        var bytes = good;
        bytes[index] = 255;
        try std.testing.expectError(error.InvalidAuthPacket, wire.decode(&bytes));
    }
    for ([_]u8{ '\r', '\n', 0 }) |char| {
        var bytes = good;
        bytes[14] = char;
        try std.testing.expectError(error.InvalidAuthPacket, wire.decode(&bytes));
    }
    var offline = wire.encode(.{ .status = .not_running });
    offline[14] = 'x';
    try std.testing.expectError(error.InvalidAuthPacket, wire.decode(&offline));
}

test "helper accepts only a nonce and parent PID, never arbitrary commands" {
    const broker = @import("auth_broker.zig");
    const nonce = "0123456789abcdef0123456789abcdef";
    const args = [_][]const u8{ "helper", "--pipe", nonce, "--parent", "42" };
    try std.testing.expectEqual(@as(u32, 42), (try broker.arguments(&args)).parent);
    try std.testing.expectError(error.InvalidHelperArguments, broker.arguments(args[0..4]));
    try std.testing.expectError(error.InvalidHelperArguments, broker.arguments(&(args ++ [_][]const u8{"--command"})));
    try std.testing.expectError(error.InvalidHelperArguments, broker.arguments(&.{ "helper", "--pipe", "C:\\any.exe", "--parent", "42" }));
    try std.testing.expectError(error.InvalidHelperArguments, broker.arguments(&.{ "helper", "--pipe", nonce, "--parent", "0" }));
}
const t = @import("types.zig");
const l = @import("logic.zig");
const auth = @import("auth.zig");
const settings = @import("settings.zig");
const testing = std.testing;
const a = testing.allocator;
const fixture =
    \\{"localPlayerCellId":0,"myTeam":[{"cellId":0,"championId":22}],"benchEnabled":true,"benchChampionIds":[99,107,1],"actions":[]}
;
const events = @import("events.zig");
const win = @import("windows.zig");
const themes = @import("theme.zig");
const grid = @import("champion_grid.zig");
const portraits = @import("portraits.zig");
const toasts = @import("toasts.zig");
test {
    _ = @import("updater.zig");
}

test "catalog identity preserves portraits across reconnects but changes with version order or labels" {
    var champs = [_]t.Champion{
        .{ .id = 1, .name = t.Text(96).init("Annie"), .alias = t.Text(64).init("Annie"), .asset = t.Text(256).init("/lol-game-data/assets/1.png") },
        .{ .id = 107, .name = t.Text(96).init("Rengar"), .alias = t.Text(64).init("Rengar"), .asset = t.Text(256).init("/lol-game-data/assets/107.png") },
    };
    const catalog = @import("catalog.zig");
    const original = catalog.generation("cache/version-a", &champs);
    champs[0].icon_path.set("cached-after-download.png");
    try testing.expectEqual(original, catalog.generation("cache/version-a", &champs));
    try testing.expect(original != catalog.generation("cache/version-b", &champs));
    std.mem.swap(t.Champion, &champs[0], &champs[1]);
    try testing.expect(original != catalog.generation("cache/version-a", &champs));
    std.mem.swap(t.Champion, &champs[0], &champs[1]);
    champs[0].name.set("安妮");
    try testing.expect(original != catalog.generation("cache/version-a", &champs));
}

test "Jade aliases are excluded regardless of case or inventory availability" {
    for ([_][]const u8{ "Jade_Ahri", "jade_lulu", "JADE_Fiora", "jAdE_Annie", "Jade_" }) |alias| try testing.expect(!l.candidateChampion(999, alias));
    for ([_][]const u8{ "Rengar", "Ahri", "Jade", "NotJade_Ahri" }) |alias| try testing.expect(l.candidateChampion(107, alias));
    try testing.expect(!l.candidateChampion(0, "None"));
}

test "success toasts queue confirmed actions once and dismiss independently" {
    const snapshot = try a.create(t.Snapshot);
    defer a.destroy(snapshot);
    snapshot.* = .{};
    var queue: toasts.State = .{};
    queue.observe(snapshot, 0);
    try testing.expectEqual(@as(usize, 0), queue.count);
    snapshot.accepted = 1;
    queue.observe(snapshot, 100);
    try testing.expectEqual(@as(usize, 1), queue.count);
    queue.observe(snapshot, 200);
    try testing.expectEqual(@as(u64, 100 + toasts.duration_ms), queue.deadline);
    snapshot.swapped = 1;
    snapshot.last_pick_name.set("傲之追猎者");
    queue.observe(snapshot, 300);
    try testing.expectEqual(@as(usize, 2), queue.count);
    try testing.expect(std.mem.indexOf(u8, queue.messages[1].body.text(), "傲之追猎者") != null);
    queue.expire(100 + toasts.duration_ms - 1);
    try testing.expectEqual(@as(usize, 2), queue.count);
    queue.expire(100 + toasts.duration_ms);
    try testing.expectEqualStrings("抢英雄成功", queue.messages[0].title.text());
    queue.dismiss(5000);
    queue.observe(snapshot, 6000);
    try testing.expectEqual(@as(usize, 0), queue.count);
    // Reconnecting cannot manufacture a success out of reset counters.
    snapshot.accepted = 0;
    snapshot.swapped = 0;
    queue.observe(snapshot, 7000);
    try testing.expectEqual(@as(usize, 0), queue.count);
}

test "continuous champion grid reaches every hero and keeps a stable scroll extent" {
    for ([_]f32{ 880, 1120, 1440, 1920 }) |width| {
        const cols = grid.columns(width);
        const occupied = @as(f32, @floatFromInt(cols)) * (grid.tile_width + grid.gap) - grid.gap;
        try testing.expect(occupied <= grid.libraryWidth(width));
    }
    try testing.expectEqual(@as(usize, 4), grid.columns(880));
    try testing.expectEqual(@as(usize, 5), grid.columns(1120));
    for ([_]usize{ 0, 1, 9, 241, t.max_champions }) |count| {
        for ([_]usize{ 2, 3, 4, 8, 10 }) |cols| {
            const rows = std.math.divCeil(usize, count, cols) catch unreachable;
            const extent = if (rows == 0) 0 else @as(f32, @floatFromInt(rows)) * grid.stride - grid.gap;
            var seen: [t.max_champions]bool = @splat(false);
            for (0..@max(1, rows)) |row| {
                const w = grid.window(count, cols, @as(f32, @floatFromInt(row)) * grid.stride, 420);
                try testing.expect(w.start <= w.end and w.end <= count);
                // At most the viewport's rows plus one overscan row per edge,
                // including when the avatar-only tiles become more compact.
                const max_rows: usize = @intFromFloat(@ceil(420 / grid.stride) + 2);
                try testing.expect(w.end - w.start <= cols * max_rows);
                const mounted_rows = std.math.divCeil(usize, w.end - w.start, cols) catch unreachable;
                const mounted = if (mounted_rows == 0) 0 else @as(f32, @floatFromInt(mounted_rows)) * grid.stride - grid.gap;
                try testing.expectApproxEqAbs(extent, w.top + mounted + w.bottom, 0.01);
                for (w.start..w.end) |i| seen[i] = true;
            }
            for (seen[0..count]) |reachable| try testing.expect(reachable);
            const tail = grid.window(count, cols, 999999, 420);
            try testing.expectEqual(count, tail.end);
        }
    }
}

test "portrait atlas covers all champions without overwriting neighboring tiles" {
    var store: portraits.Store = .{};
    defer store.deinit(a);
    const red = [_]u8{ 255, 0, 0, 255 };
    const blue = [_]u8{ 0, 0, 255, 255 };
    _ = try store.put(a, 0, 1, 1, &red);
    _ = try store.put(a, 1, 1, 1, &blue);
    for (0..t.max_champions) |index| {
        const bytes = try store.put(a, index, 1, 1, &blue);
        const start = (portraits.y(index) * portraits.side + portraits.x(index)) * 4;
        const end = ((portraits.y(index) + portraits.tile - 1) * portraits.side + portraits.x(index) + portraits.tile - 1) * 4;
        try testing.expectEqualSlices(u8, &blue, bytes[start..][0..4]);
        try testing.expectEqualSlices(u8, &blue, bytes[end..][0..4]);
        // One additional slot is reserved for the account avatar.
        try testing.expect(portraits.imageId(index) - portraits.imageId(0) < 15);
    }
    _ = try store.put(a, 0, 1, 1, &red);
    try testing.expectEqualSlices(u8, &blue, store.pixels[0][portraits.tile * 4 ..][0..4]);
    try testing.expectError(error.InvalidPortrait, store.put(a, t.max_champions, 1, 1, &red));
}

test "theme settings preserve automation and migrate missing or unknown names" {
    for ([_][]const u8{
        "{\"auto_accept\":true,\"priority\":[107,99]}",
        "{\"theme\":\"future-theme\",\"auto_accept\":true,\"priority\":[107,99]}",
    }) |json| {
        const loaded = try settings.decode(a, json);
        try testing.expectEqual(themes.Preset.classic_gold, loaded.theme);
        try testing.expect(loaded.auto_accept);
        try testing.expectEqualSlices(i32, &.{ 107, 99 }, loaded.ids());
    }
    var prefs = preferences();
    prefs.auto_accept = true;
    for (themes.presets) |preset| {
        prefs.theme = preset;
        const json = try settings.encode(a, &prefs);
        defer a.free(json);
        const restored = try settings.decode(a, json);
        try testing.expectEqualDeep(prefs, restored);
    }
}

test "theme changes replace the local settings file and survive reopening" {
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    const path = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &dir.sub_path, "settings.json" });
    defer a.free(path);
    var prefs = preferences();
    prefs.auto_accept = true;
    for (themes.presets) |preset| {
        prefs.theme = preset;
        try settings.save(a, testing.io, path, &prefs);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(64 * 1024));
        defer a.free(bytes);
        try testing.expectEqualDeep(prefs, try settings.decode(a, bytes));
    }
}

fn luminance(rgb: u24) f64 {
    var channels: [3]f64 = .{ @as(f64, @floatFromInt(rgb >> 16)) / 255, @as(f64, @floatFromInt((rgb >> 8) & 255)) / 255, @as(f64, @floatFromInt(rgb & 255)) / 255 };
    for (&channels) |*value| value.* = if (value.* <= 0.04045) value.* / 12.92 else std.math.pow(f64, (value.* + 0.055) / 1.055, 2.4);
    return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722;
}
fn contrast(fg: u24, bg: u24) f64 {
    const x = luminance(fg);
    const y = luminance(bg);
    return (@max(x, y) + 0.05) / (@min(x, y) + 0.05);
}
test "all themes keep body muted and selected-button text readable" {
    for (themes.presets) |preset| {
        const p = themes.palette(preset);
        for ([_]u24{ p.background, p.surface, p.subtle }) |background| {
            try testing.expect(contrast(p.text, background) >= 4.5);
            try testing.expect(contrast(p.muted, background) >= 4.5);
        }
        try testing.expect(contrast(p.accent_text, p.accent) >= 4.5);
    }
}

fn event(cache: *events.Cache, path: []const u8, kind: []const u8, data: []const u8) !void {
    const frame = try std.fmt.allocPrint(a, "[8,\"OnJsonApiEvent\",{{\"uri\":\"{s}\",\"eventType\":\"{s}\",\"data\":{s}}}]", .{ path, kind, data });
    defer a.free(frame);
    try testing.expect(try cache.apply(frame));
}

test "WS snapshots do not overwrite a newer event or a resource deletion" {
    var cache: events.Cache = .{};
    defer cache.deinit();
    const revision = cache.version(3);
    try event(&cache, events.paths[3], "Update", fixture);
    try cache.seed(3, revision, .{ .status = 200, .body = "{}" });
    var response = try cache.read(a, 3);
    try testing.expect(std.mem.indexOf(u8, response.body, "107") != null);
    a.free(response.body);
    const before_delete = cache.version(3);
    try event(&cache, events.paths[3], "Delete", "null");
    try cache.seed(3, before_delete, .{ .status = 200, .body = fixture });
    response = try cache.read(a, 3);
    defer a.free(response.body);
    try testing.expectEqual(@as(u32, 404), response.status);
}

test "WS phase exit invalidates the previous match and ignores unrelated topics" {
    var cache: events.Cache = .{};
    defer cache.deinit();
    try event(&cache, events.paths[0], "Update", "\"ChampSelect\"");
    try event(&cache, events.paths[1], "Update", "{\"phase\":\"ChampSelect\",\"gameData\":{\"queue\":{\"id\":450}}}");
    try event(&cache, events.paths[3], "Update", fixture);
    try event(&cache, events.paths[4], "Update", "[107,99]");
    try event(&cache, events.paths[0], "Update", "\"Lobby\"");
    for ([_]usize{ 1, 3, 4 }) |i| {
        const response = try cache.read(a, i);
        defer a.free(response.body);
        try testing.expectEqual(@as(u32, 404), response.status);
    }
    try testing.expect(!try cache.apply("[8,\"Other\",{\"uri\":\"/lol-gameflow/v1/gameflow-phase\",\"eventType\":\"Update\",\"data\":\"ReadyCheck\"}]"));
    try testing.expect(!try cache.apply("[0,\"welcome\",1,{}]"));
    try testing.expect(!try cache.apply(""));
    const version = cache.phaseVersion();
    try event(&cache, events.paths[0], "Update", "\"Lobby\"");
    try testing.expectEqual(version, cache.phaseVersion());
}

test "WS game event preceding its phase is preserved and cached reads need no REST" {
    var cache: events.Cache = .{};
    defer cache.deinit();
    try event(&cache, events.paths[0], "Update", "\"Lobby\"");
    try event(&cache, events.paths[1], "Update", "{\"phase\":\"ChampSelect\",\"gameData\":{\"queue\":{\"id\":2400}}}");
    try event(&cache, events.paths[3], "Update", fixture);
    try event(&cache, events.paths[0], "Update", "\"ChampSelect\"");
    const service = try a.create(@import("service.zig").Service);
    defer a.destroy(service);
    service.* = .{};
    const state = try a.create(t.Snapshot);
    defer a.destroy(state);
    state.* = .{};
    // An undefined REST pointer deliberately makes accidental network reads fail.
    var client: events.CachedClient = .{ .rest = undefined, .cache = &cache };
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    var gate: l.RetryGate = .{};
    var accept: l.RetryGate = .{};
    try service.tick(arena.allocator(), &client, state, &gate, &accept);
    try testing.expectEqual(@as(i32, 2400), state.queue_id);
    try testing.expectEqual(@as(i32, 22), state.current);
    try testing.expectEqual(@as(usize, 3), state.bench_count);
    // An event racing a decision prevents its write from reaching REST.
    try event(&cache, events.paths[0], "Update", "\"Lobby\"");
    const rejected = try client.request(a, "POST", "/lol-champ-select/v1/session/bench/swap/107", "");
    try testing.expectEqual(@as(u32, 409), rejected.status);
    cache.invalidate();
    const disconnected = try cache.read(a, 0);
    defer a.free(disconnected.body);
    try testing.expectEqual(@as(u32, 404), disconnected.status);
}

test "single instance rejects duplicate launch, signals activation, and releases on exit" {
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &dir.sub_path });
    defer a.free(root);
    const Instance = @import("instance.zig").Instance;
    var first = (try Instance.acquire(a, testing.io, root)).?;
    var released = false;
    defer if (!released) first.deinit();
    try testing.expect((try Instance.acquire(a, testing.io, root)) == null);
    try testing.expectEqual(@as(u32, win.c.WAIT_OBJECT_0), win.c.WaitForSingleObject(first.activation, 100));
    first.deinit();
    released = true;
    var second = (try Instance.acquire(a, testing.io, root)).?;
    defer second.deinit();
}

fn preferences() t.Preferences {
    var p: t.Preferences = .{ .auto_pick = true };
    p.add(107);
    p.add(99);
    p.add(22);
    return p;
}
fn parse(bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, bytes, .{});
}

test "ARAM and Mayhem choose the highest ranked available champion" {
    const session = try parse(fixture);
    defer session.deinit();
    var p = preferences();
    for ([_]i32{ 450, 2400 }) |queue| try testing.expectEqual(@as(i32, 107), l.choose(&p, queue, "", session.value, &.{}).?.champion);
    try testing.expect(l.choose(&p, 420, "CLASSIC", session.value, &.{}) == null);
    p.auto_pick = false;
    try testing.expect(l.choose(&p, 450, "ARAM", session.value, &.{}) == null);
}
test "never downgrade an existing better champion or invent an unavailable one" {
    const session = try parse(fixture);
    defer session.deinit();
    var p: t.Preferences = .{ .auto_pick = true };
    p.add(22);
    p.add(107);
    try testing.expect(l.choose(&p, 450, "", session.value, &.{}) == null);
    p = .{ .auto_pick = true };
    p.add(999);
    try testing.expect(l.choose(&p, 450, "", session.value, &.{}) == null);
}
test "modern bench honors availability and team-builder routing" {
    const s = try parse(
        \\{"localPlayerCellId":3,"myTeam":[{"cellId":3,"championId":22}],"benchEnabled":true,"isLegacyChampSelect":false,"benchChampions":[{"championId":107,"isAvailable":false},{"championId":99,"isAvailable":true}]}
    );
    defer s.deinit();
    var p = preferences();
    const choice = l.choose(&p, 2400, "", s.value, &.{}).?;
    try testing.expectEqual(@as(i32, 99), choice.champion);
    try testing.expect(!choice.legacy);
}
test "spectator malformed and absent-local sessions cannot trigger writes" {
    var p = preferences();
    for ([_][]const u8{ "{}", "null", "{\"isSpectating\":true}", "{\"localPlayerCellId\":-1,\"benchEnabled\":true,\"benchChampionIds\":[107]}" }) |bytes| {
        const s = try parse(bytes);
        defer s.deinit();
        try testing.expect(l.choose(&p, 450, "ARAM", s.value, &.{107}) == null);
    }
}
test "card pick requires our active action and pickable champion" {
    const s = try parse(
        \\{"localPlayerCellId":2,"myTeam":[{"cellId":2,"championId":0}],"actions":[[{"id":7,"actorCellId":1,"type":"pick","isInProgress":true,"completed":false},{"id":8,"actorCellId":2,"type":"pick","isInProgress":true,"completed":false}]]}
    );
    defer s.deinit();
    var p = preferences();
    try testing.expect(l.choose(&p, 450, "", s.value, &.{}) == null);
    const choice = l.choose(&p, 450, "", s.value, &.{107}).?;
    try testing.expectEqual(@as(?i32, 8), choice.action);
}
test "ready checks only accept pending local None response" {
    for ([_][]const u8{ "None", "Accepted", "Declined" }) |answer| {
        const json = try std.fmt.allocPrint(a, "{{\"state\":\"InProgress\",\"playerResponse\":\"{s}\"}}", .{answer});
        defer a.free(json);
        const s = try parse(json);
        defer s.deinit();
        try testing.expectEqual(std.mem.eql(u8, answer, "None"), l.shouldAccept(true, "ReadyCheck", s.value));
        try testing.expect(!l.shouldAccept(false, "ReadyCheck", s.value));
        try testing.expect(!l.shouldAccept(true, "Lobby", s.value));
    }
}
test "retry backs off failed target but lets a new higher target through immediately" {
    var gate: l.RetryGate = .{};
    try testing.expect(gate.allowed(99, 0));
    gate.record(0, false);
    try testing.expect(!gate.allowed(99, 200));
    try testing.expect(gate.allowed(107, 200));
    gate.record(200, true);
    try testing.expect(!gate.allowed(107, 900));
    try testing.expect(gate.allowed(107, 1200));
}
test "settings roundtrip preserves order and removes duplicates invalid ids" {
    var p = try settings.decode(a, "{\"version\":1,\"priority\":[107,99,107,-1,0],\"auto_accept\":true}");
    try testing.expectEqualSlices(i32, &.{ 107, 99 }, p.ids());
    p.move(99, true);
    try testing.expectEqualSlices(i32, &.{ 99, 107 }, p.ids());
    const bytes = try settings.encode(a, &p);
    defer a.free(bytes);
    var restored = try settings.decode(a, bytes);
    try testing.expectEqualSlices(i32, p.ids(), restored.ids());
    try testing.expect(restored.auto_accept);
    restored.remove(99);
    try testing.expectEqualSlices(i32, &.{107}, restored.ids());
    try testing.expectError(error.UnsupportedSettingsVersion, settings.decode(a, "{\"version\":2}"));
}
test "authentication rejects invalid port and token without exposing secrets" {
    const creds = try auth.parse(a, "{\"port\":12345,\"pid\":44,\"token\":\"test-only\"}");
    try testing.expectEqual(@as(u16, 12345), creds.port);
    try testing.expectError(error.InvalidCredentials, auth.parse(a, "{\"port\":0,\"pid\":44,\"token\":\"test-only\"}"));
    try testing.expectError(error.InvalidCredentials, auth.parse(a, "{\"port\":1,\"pid\":44,\"token\":\"x\\n\"}"));
}

test "credential monitoring detects token port and process replacement and clears secrets on exit" {
    var identity: auth.Identity = .{};
    var creds: auth.Credentials = .{ .pid = 10, .port = 12345, .token = t.Text(256).init("fixture-one") };
    identity.update(.ready, creds);
    var recovery: auth.Recovery = .{};
    recovery.connected(identity);
    identity.update(.ready, creds);
    try testing.expect(!recovery.changed(identity));
    creds.token.set("fixture-two");
    identity.update(.ready, creds);
    try testing.expect(recovery.changed(identity));
    recovery.connected(identity);
    creds.port += 1;
    identity.update(.ready, creds);
    try testing.expect(recovery.changed(identity));
    recovery.connected(identity);
    creds.pid += 1;
    identity.update(.ready, creds);
    try testing.expect(recovery.changed(identity));
    recovery.connected(identity);
    identity.update(.not_running, null);
    try testing.expect(recovery.changed(identity));
    try testing.expectEqual(@as(u32, 0), identity.credentials.pid);
    try testing.expectEqual(@as(usize, 0), identity.credentials.token.len);
    for (identity.credentials.token.bytes) |byte| try testing.expectEqual(@as(u8, 0), byte);
    try testing.expect(!recovery.available(identity, 10000));
    identity.update(.ready, creds);
    try testing.expect(recovery.available(identity, 10000));
}

test "reconnect waits for fresh discovery and backoff even when token is unchanged" {
    var identity: auth.Identity = .{};
    const creds: auth.Credentials = .{ .pid = 10, .port = 12345, .token = t.Text(256).init("fixture") };
    identity.update(.ready, creds);
    var recovery: auth.Recovery = .{};
    recovery.connected(identity);
    recovery.failed(identity, 1000);
    try testing.expect(!recovery.available(identity, 10000));
    identity.update(.ready, creds);
    try testing.expect(!recovery.available(identity, 1999));
    try testing.expect(recovery.available(identity, 2000));
    recovery.connected(identity);
    identity.update(.admin_required, null);
    try testing.expect(recovery.changed(identity));
    try testing.expect(!recovery.available(identity, 10000));
}

test "health probe repairs missed phase and invalidates the previous selection" {
    var cache: events.Cache = .{};
    defer cache.deinit();
    try cache.seed(0, cache.version(0), .{ .status = 200, .body = "\"ChampSelect\"" });
    try cache.seed(3, cache.version(3), .{ .status = 200, .body = fixture });
    var client: Mock = .{ .steps = &.{.{ .method = "GET", .path = events.paths[0], .body = "\"Lobby\"" }} };
    try cache.health(a, &client);
    const response = try cache.read(a, 3);
    defer a.free(response.body);
    try testing.expectEqual(@as(u32, 404), response.status);
    try testing.expectEqualStrings("Lobby", cache.phase.text());
}

test "401 and 403 in health ready check and accept force recovery without success" {
    const service = try a.create(@import("service.zig").Service);
    defer a.destroy(service);
    const state = try a.create(t.Snapshot);
    defer a.destroy(state);
    for ([_]u32{ 401, 403 }) |status| {
        var cache: events.Cache = .{};
        defer cache.deinit();
        var health: Mock = .{ .steps = &.{.{ .method = "GET", .path = events.paths[0], .body = "{}", .status = status }} };
        try testing.expectError(error.AuthenticationExpired, cache.health(a, &health));
        for ([_]bool{ false, true }) |write| {
            service.* = .{};
            service.preferences.auto_accept = true;
            state.* = .{};
            var gate: l.RetryGate = .{};
            var accept: l.RetryGate = .{};
            const steps = [_]Mock.Step{
                .{ .method = "GET", .path = events.paths[0], .body = "\"ReadyCheck\"" },
                .{ .method = "GET", .path = events.paths[2], .body = "{\"state\":\"InProgress\",\"playerResponse\":\"None\"}", .status = if (write) 200 else status },
                .{ .method = "POST", .path = "/lol-matchmaking/v1/ready-check/accept", .body = "{}", .status = status },
            };
            var client: Mock = .{ .steps = steps[0..if (write) @as(usize, 3) else 2] };
            try testing.expectError(error.AuthenticationExpired, service.tick(a, &client, state, &gate, &accept));
            try testing.expectEqual(client.steps.len, client.cursor);
            try testing.expectEqual(@as(usize, 0), state.accepted);
        }
    }
}
test "asset fetches cannot escape LCU namespace or inject remote URLs" {
    try testing.expect(l.validAsset("/lol-game-data/assets/v1/champion-icons/107.png"));
    for ([_][]const u8{ "https://example.org/x", "/lol-game-data/assets/../../token", "/lol-game-data/assets/%2e/x", "/lol-game-data/assets/x?redirect=evil", "/lol-game-data/assets/x\\y" }) |path| try testing.expect(!l.validAsset(path));
}
test "fixed text truncation keeps valid UTF-8" {
    const value = t.Text(4).init("英雄");
    try testing.expectEqualStrings("英", value.text());
}

const Mock = struct {
    const Step = struct { method: []const u8, path: []const u8, body: []const u8, status: u32 = 200 };
    steps: []const Step,
    cursor: usize = 0,
    pub fn request(self: *@This(), allocator: std.mem.Allocator, method: []const u8, path: []const u8, body: []const u8) !@import("lcu.zig").Response {
        _ = allocator;
        _ = body;
        try testing.expect(self.cursor < self.steps.len);
        const step = self.steps[self.cursor];
        self.cursor += 1;
        try testing.expectEqualStrings(step.method, method);
        try testing.expectEqualStrings(step.path, path);
        return .{ .status = step.status, .body = step.body };
    }
};

test "current account uses exact Riot ID, supports Unicode and never copies internal IDs" {
    const profile = @import("profile.zig");
    const json = try std.json.parseFromSlice(std.json.Value, a,
        \\{"gameName":"峡谷 小猫🐈","displayName":"旧名字","tagLine":"CN123","profileIconId":0,"summonerId":999999}
    , .{});
    defer json.deinit();
    const value = profile.parse(json.value);
    try testing.expectEqualStrings("峡谷 小猫🐈", value.name.text());
    try testing.expectEqualStrings("峡谷 小猫🐈#CN123", value.riot_id.text());
    try testing.expectEqual(@as(?u32, 0), value.icon_id);
    for ([_][]const u8{
        "{\"displayName\":\"Old Name\",\"summonerId\":123}",
        "{\"gameName\":\"New Name\",\"tagLine\":\"\"}",
        "{\"gameName\":\"New Name\",\"tagLine\":\"bad#tag\"}",
        "{\"gameName\":\"New Name\",\"tagLine\":\"bad\\nID\"}",
        "null",
    }) |body| {
        const invalid = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        defer invalid.deinit();
        try testing.expectEqual(@as(usize, 0), profile.parse(invalid.value).riot_id.len);
    }
    const oversized = try std.fmt.allocPrint(a, "{{\"gameName\":\"{s}\",\"tagLine\":\"CN1\"}}", .{"x" ** 97});
    defer a.free(oversized);
    const long = try std.json.parseFromSlice(std.json.Value, a, oversized, .{});
    defer long.deinit();
    try testing.expectEqual(@as(usize, 0), profile.parse(long.value).riot_id.len);
}

test "account refresh clears stale users and avatars after logout, auth errors and account changes" {
    const profile = @import("profile.zig");
    var value: t.Profile = .{ .name = t.Text(96).init("Old"), .riot_id = t.Text(128).init("Old#123"), .icon_id = 5, .icon_path = t.Text(768).init("old-avatar.jpg") };
    const bodies = [_][]const u8{
        "{\"gameName\":\"New\",\"tagLine\":\"CN1\",\"profileIconId\":5}",
        "{\"gameName\":\"New\",\"tagLine\":\"CN1\",\"profileIconId\":6}",
        "null",
    };
    for (bodies, 0..) |body, i| {
        var client: Mock = .{ .steps = &.{.{ .method = "GET", .path = profile.endpoint, .body = body }} };
        try profile.refresh(a, &client, &value);
        if (i == 0) {
            try testing.expectEqualStrings("New#CN1", value.riot_id.text());
            try testing.expectEqualStrings("old-avatar.jpg", value.icon_path.text());
        } else try testing.expectEqual(@as(usize, 0), value.icon_path.len);
    }
    for ([_]u32{ 404, 500, 401, 403 }) |status| {
        value.name.set("Old");
        value.riot_id.set("Old#123");
        var client: Mock = .{ .steps = &.{.{ .method = "GET", .path = profile.endpoint, .body = "{}", .status = status }} };
        if (status == 401 or status == 403) {
            try testing.expectError(error.AuthenticationExpired, profile.refresh(a, &client, &value));
        } else try profile.refresh(a, &client, &value);
        try testing.expectEqualDeep(t.Profile{}, value);
    }
    const state = try a.create(t.Snapshot);
    defer a.destroy(state);
    state.* = .{};
    state.profile.name.set("Account");
    try testing.expect(!profile.visible(state));
    state.connected = true;
    try testing.expect(profile.visible(state));
    state.profile = .{};
    try testing.expect(!profile.visible(state));
}

test "summoner update and delete events replace the current account without polling" {
    var cache: events.Cache = .{};
    defer cache.deinit();
    const index = @intFromEnum(events.Slot.summoner);
    try testing.expect(try cache.apply(
        \\[8,"OnJsonApiEvent_lol-summoner_v1_current-summoner",{"uri":"/lol-summoner/v1/current-summoner","eventType":"Update","data":{"gameName":"猫","tagLine":"CN1","profileIconId":29}}]
    ));
    const response = try cache.read(a, index);
    defer a.free(response.body);
    const json = try response.json(a);
    defer json.deinit();
    try testing.expectEqualStrings("猫#CN1", @import("profile.zig").parse(json.value).riot_id.text());
    try testing.expect(try cache.apply(
        \\[8,"OnJsonApiEvent_lol-summoner_v1_current-summoner",{"uri":"/lol-summoner/v1/current-summoner","eventType":"Delete","data":null}]
    ));
    const deleted = try cache.read(a, index);
    defer a.free(deleted.body);
    try testing.expectEqual(@as(u32, 404), deleted.status);
}
test "automation flow confirms a swap from a fresh session" {
    const service = try a.create(@import("service.zig").Service);
    defer a.destroy(service);
    service.* = .{};
    service.preferences = preferences();
    const state = try a.create(t.Snapshot);
    defer a.destroy(state);
    state.* = .{};
    var client: Mock = .{ .steps = &.{
        .{ .method = "GET", .path = "/lol-gameflow/v1/gameflow-phase", .body = "\"ChampSelect\"" },
        .{ .method = "GET", .path = "/lol-gameflow/v1/session", .body = "{\"gameData\":{\"queue\":{\"id\":2400}}}" },
        .{ .method = "GET", .path = "/lol-champ-select/v1/session", .body = fixture },
        .{ .method = "POST", .path = "/lol-champ-select/v1/session/bench/swap/107", .body = "", .status = 204 },
        .{ .method = "GET", .path = "/lol-gameflow/v1/gameflow-phase", .body = "\"ChampSelect\"" },
        .{ .method = "GET", .path = "/lol-gameflow/v1/session", .body = "{\"gameData\":{\"queue\":{\"id\":2400}}}" },
        .{ .method = "GET", .path = "/lol-champ-select/v1/session", .body = "{\"localPlayerCellId\":0,\"myTeam\":[{\"cellId\":0,\"championId\":107}]}" },
    } };
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    var gate: l.RetryGate = .{};
    var accept: l.RetryGate = .{};
    var toast: toasts.State = .{};
    try service.tick(arena.allocator(), &client, state, &gate, &accept);
    try testing.expectEqual(@as(?bool, true), state.pick_supported);
    toast.observe(state, 0);
    try testing.expectEqual(@as(usize, 0), toast.count);
    try testing.expectEqual(@as(usize, 0), state.swapped);
    try testing.expectEqual(@as(i32, 107), service.pending_pick);
    try testing.expectEqual(t.LogLevel.info, state.logs[0].level);
    try testing.expect(std.mem.indexOf(u8, state.logs[0].message.text(), "等待归属确认") != null);
    try service.tick(arena.allocator(), &client, state, &gate, &accept);
    toast.observe(state, 100);
    try testing.expectEqual(@as(usize, 1), toast.count);
    try testing.expectEqualStrings("抢英雄成功", toast.messages[0].title.text());
    try testing.expectEqual(client.steps.len, client.cursor);
    try testing.expectEqual(@as(usize, 1), state.swapped);
    try testing.expectEqual(t.LogKind.pick, state.logs[0].kind);
    try testing.expectEqual(t.LogLevel.success, state.logs[0].level);
    try testing.expect(std.mem.indexOf(u8, state.logs[0].message.text(), "客户端已确认归属") != null);
}
test "disabled auto-accept reads phase without submitting a write" {
    const service = try a.create(@import("service.zig").Service);
    defer a.destroy(service);
    service.* = .{};
    const state = try a.create(t.Snapshot);
    defer a.destroy(state);
    state.* = .{};
    state.pick_supported = true;
    var client: Mock = .{ .steps = &.{.{ .method = "GET", .path = "/lol-gameflow/v1/gameflow-phase", .body = "\"ReadyCheck\"" }} };
    var gate: l.RetryGate = .{};
    var accept: l.RetryGate = .{};
    try service.tick(a, &client, state, &gate, &accept);
    try testing.expectEqual(@as(usize, 1), client.cursor);
    try testing.expectEqual(@as(?bool, null), state.pick_supported);
}

test "successful accept is submitted once until the ready check ends" {
    const service = try a.create(@import("service.zig").Service);
    defer a.destroy(service);
    service.* = .{};
    service.preferences.auto_accept = true;
    const state = try a.create(t.Snapshot);
    defer a.destroy(state);
    state.* = .{};
    const ready = "{\"state\":\"InProgress\",\"playerResponse\":\"None\"}";
    var client: Mock = .{ .steps = &.{
        .{ .method = "GET", .path = "/lol-gameflow/v1/gameflow-phase", .body = "\"ReadyCheck\"" },
        .{ .method = "GET", .path = "/lol-matchmaking/v1/ready-check", .body = ready },
        .{ .method = "POST", .path = "/lol-matchmaking/v1/ready-check/accept", .body = "", .status = 204 },
        .{ .method = "GET", .path = "/lol-gameflow/v1/gameflow-phase", .body = "\"ReadyCheck\"" },
        .{ .method = "GET", .path = "/lol-matchmaking/v1/ready-check", .body = ready },
    } };
    var gate: l.RetryGate = .{};
    var accept: l.RetryGate = .{};
    try service.tick(a, &client, state, &gate, &accept);
    try service.tick(a, &client, state, &gate, &accept);
    try testing.expectEqual(@as(usize, 1), state.accepted);
    try testing.expectEqual(t.LogKind.accept, state.logs[0].kind);
    try testing.expectEqual(t.LogLevel.success, state.logs[0].level);
    var accept_logs: usize = 0;
    for (state.logs[0..state.log_count]) |entry| if (entry.kind == .accept) {
        accept_logs += 1;
    };
    try testing.expectEqual(@as(usize, 1), accept_logs);
    try testing.expectEqual(client.steps.len, client.cursor);
}

test "HTTP competition failure is not counted as a swap" {
    const service = try a.create(@import("service.zig").Service);
    defer a.destroy(service);
    service.* = .{};
    service.preferences = preferences();
    const state = try a.create(t.Snapshot);
    defer a.destroy(state);
    state.* = .{};
    var client: Mock = .{ .steps = &.{
        .{ .method = "GET", .path = "/lol-gameflow/v1/gameflow-phase", .body = "\"ChampSelect\"" },
        .{ .method = "GET", .path = "/lol-gameflow/v1/session", .body = "{\"gameData\":{\"queue\":{\"id\":450}}}" },
        .{ .method = "GET", .path = "/lol-champ-select/v1/session", .body = fixture },
        .{ .method = "POST", .path = "/lol-champ-select/v1/session/bench/swap/107", .body = "{}", .status = 409 },
    } };
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    var gate: l.RetryGate = .{};
    var accept: l.RetryGate = .{};
    try service.tick(arena.allocator(), &client, state, &gate, &accept);
    try testing.expectEqual(@as(usize, 0), state.swapped);
    try testing.expectEqual(@as(u8, 1), gate.attempts);
    try testing.expectEqual(t.LogLevel.failure, state.logs[0].level);
    try testing.expect(std.mem.indexOf(u8, state.logs[0].message.text(), "HTTP 409") != null);
}

test "ranked session is gated before champion selection endpoints" {
    const service = try a.create(@import("service.zig").Service);
    defer a.destroy(service);
    service.* = .{};
    service.preferences = preferences();
    const state = try a.create(t.Snapshot);
    defer a.destroy(state);
    state.* = .{};
    var client: Mock = .{ .steps = &.{
        .{ .method = "GET", .path = "/lol-gameflow/v1/gameflow-phase", .body = "\"ChampSelect\"" },
        .{ .method = "GET", .path = "/lol-gameflow/v1/session", .body = "{\"gameData\":{\"queue\":{\"id\":420,\"gameMode\":\"CLASSIC\"}}}" },
    } };
    var gate: l.RetryGate = .{};
    var accept: l.RetryGate = .{};
    try service.tick(a, &client, state, &gate, &accept);
    try testing.expectEqual(client.steps.len, client.cursor);
    try testing.expectEqual(@as(?bool, false), state.pick_supported);
}

test "connection notices keep actionable failures visible without surfacing protocol logs" {
    const ui = @import("ui_state.zig");
    const state = try a.create(t.Snapshot);
    defer a.destroy(state);
    state.* = .{};
    state.status.set("WebSocket 暂不可用，REST 降级");
    state.connection = .waiting_client;
    try testing.expectEqualStrings("", ui.connectionNotice(state));
    for ([_]t.ConnectionState{ .permission_required, .helper_missing, .helper_failed, .failed, .reconnecting, .authorizing }) |connection| {
        state.connection = connection;
        try testing.expect(ui.connectionNotice(state).len > 0);
    }
    state.settings_error.set("设置保存失败");
    state.connected = true;
    state.phase.set("None");
    try testing.expectEqualStrings("客户端已连接", ui.connectionLabel(state));
    try testing.expectEqualStrings("空闲", ui.phaseLabel(state));
    state.phase.set("Matchmaking");
    try testing.expectEqualStrings("客户端已连接", ui.connectionLabel(state));
    try testing.expectEqualStrings("匹配中", ui.phaseLabel(state));
    state.phase.set("FuturePhase");
    try testing.expectEqualStrings("对局状态待同步", ui.phaseLabel(state));
    try testing.expectEqualStrings("", ui.connectionNotice(state));
    try testing.expectEqualStrings("设置保存失败", state.settings_error.text());
    state.connected = false;
    try testing.expectEqualStrings("", ui.phaseLabel(state));
}
