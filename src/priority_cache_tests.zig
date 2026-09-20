const std = @import("std");
const testing = std.testing;
const a = testing.allocator;
const io = testing.io;
const t = @import("types.zig");
const cache = @import("priority_cache.zig");

fn champion(id: i32, name: []const u8, alias: []const u8) t.Champion {
    var result: t.Champion = .{ .id = id, .name = t.Text(96).init(name), .alias = t.Text(64).init(alias) };
    var buffer: [256]u8 = undefined;
    result.asset.set(std.fmt.bufPrint(&buffer, "/lol-game-data/assets/v1/champion-icons/{d}.png", .{id}) catch unreachable);
    return result;
}

fn snapshot() !*t.Snapshot {
    const state = try a.create(t.Snapshot);
    state.* = .{};
    state.champion_count = 3;
    state.champions[0] = champion(1, "安妮", "Annie");
    state.champions[1] = champion(107, "雷恩加尔", "Rengar");
    state.champions[2] = champion(99, "拉克丝", "Lux");
    return state;
}

test "application startup restores selected heroes and portraits without connecting to LCU" {
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &dir.sub_path });
    defer a.free(root);
    const state = try snapshot();
    defer a.destroy(state);
    try dir.dir.createDirPath(io, "cache/version-one");
    try dir.dir.writeFile(io, .{ .sub_path = "cache/version-one/champion-107.png", .data = "fixture portrait" });
    const portrait = try std.fs.path.join(a, &.{ root, "cache", "version-one", "champion-107.png" });
    defer a.free(portrait);
    state.champions[1].icon_path.set(portrait);
    var prefs: t.Preferences = .{ .auto_accept = true, .auto_pick = true };
    prefs.add(107);
    prefs.add(99);
    var saved: cache.Cache = .{};
    saved.update(&prefs, state);
    try saved.save(a, io, root);
    const settings_path = try std.fs.path.join(a, &.{ root, "settings.json" });
    defer a.free(settings_path);
    try @import("settings.zig").save(a, io, settings_path, &prefs);

    const service = try a.create(@import("service.zig").Service);
    defer a.destroy(service);
    service.* = .{};
    try service.initAt(io, root);
    defer service.deinit();
    try testing.expect(!service.snapshot.connected);
    try testing.expect(service.thread == null);
    try testing.expectEqualDeep(prefs, service.preferences);
    try testing.expectEqual(@as(usize, 2), service.snapshot.champion_count);
    try testing.expectEqualDeep(state.champions[1], service.snapshot.champions[0]);
    try testing.expectEqualDeep(state.champions[2], service.snapshot.champions[1]);
    try testing.expectEqual(@as(usize, 1), service.snapshot.icon_count);
    try testing.expect(service.snapshot.catalog_generation > 0);
    var detail: @import("champion_details.zig").State = .{};
    detail.begin(service.snapshot.champions[0].id, service.snapshot.champions[0].name.text());
    try testing.expectEqualStrings("雷恩加尔", detail.name.text());
    try testing.expectEqualStrings("https://haidou.pro/champion/107/", detail.url.text());

    // Reorder and remove while offline; only the current priorities are restored.
    prefs.move(99, true);
    saved.update(&prefs, &service.snapshot);
    try saved.save(a, io, root);
    prefs.remove(107);
    const restored = try a.create(t.Snapshot);
    defer a.destroy(restored);
    restored.* = .{};
    var reopened: cache.Cache = .{};
    try reopened.restore(a, io, root, &prefs, restored);
    try testing.expectEqual(@as(usize, 1), restored.champion_count);
    try testing.expectEqualStrings("拉克丝", restored.champions[0].name.text());
}

test "fresh metadata preserves the old portrait until its replacement is downloaded" {
    const state = try snapshot();
    defer a.destroy(state);
    var prefs: t.Preferences = .{};
    prefs.add(107);
    var saved: cache.Cache = .{};
    state.champions[1].icon_path.set("cache/old/champion-107.png");
    saved.update(&prefs, state);
    state.champions[1].name.set("Rengar 更新");
    state.champions[1].icon_path.set("");
    saved.update(&prefs, state);
    try testing.expectEqualStrings("Rengar 更新", saved.champions[0].name.text());
    try testing.expectEqualStrings("cache/old/champion-107.png", saved.champions[0].icon_path.text());
    // A reconnect's incomplete catalog cannot erase an existing priority.
    state.champion_count = 0;
    saved.update(&prefs, state);
    try testing.expectEqual(@as(usize, 1), saved.count);
    state.champion_count = 3;
    state.champions[1].icon_path.set("cache/new/champion-107.png");
    saved.update(&prefs, state);
    try testing.expectEqualStrings("cache/new/champion-107.png", saved.champions[0].icon_path.text());
    prefs.remove(107);
    saved.update(&prefs, state);
    try testing.expectEqual(@as(usize, 0), saved.count);
}

test "missing or unsafe cached portraits keep labels and never escape the cache directory" {
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &dir.sub_path });
    defer a.free(root);
    const state = try a.create(t.Snapshot);
    defer a.destroy(state);
    var prefs: t.Preferences = .{};
    prefs.add(107);
    try dir.dir.writeFile(io, .{ .sub_path = "outside.png", .data = "not a cached portrait" });
    for ([_][]const u8{ "cache/missing.png", "cache/../outside.png", "cache\\..\\outside.png", "https://example.org/image.png", "C:\\outside.png" }) |portrait| {
        const bytes = try std.json.Stringify.valueAlloc(a, .{ .version = 1, .champions = .{.{ .id = 107, .name = "雷恩加尔", .alias = "Rengar", .asset = "/lol-game-data/assets/107.png", .portrait = portrait }} }, .{});
        defer a.free(bytes);
        try dir.dir.writeFile(io, .{ .sub_path = "priority-champions.json", .data = bytes });
        var saved: cache.Cache = .{};
        state.* = .{};
        try saved.restore(a, io, root, &prefs, state);
        try testing.expectEqualStrings("雷恩加尔", state.champions[0].name.text());
        try testing.expectEqual(@as(usize, 0), state.champions[0].icon_path.len);
        try testing.expectEqual(@as(usize, 0), state.icon_count);
    }
}

test "missing and corrupt caches do not prevent application startup or change preferences" {
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &dir.sub_path });
    defer a.free(root);
    const settings_path = try std.fs.path.join(a, &.{ root, "settings.json" });
    defer a.free(settings_path);
    var prefs: t.Preferences = .{ .auto_accept = true };
    prefs.add(107);
    try @import("settings.zig").save(a, io, settings_path, &prefs);
    for ([_]?[]const u8{ null, "truncated {", "{\"version\":99,\"champions\":[]}" }) |bytes| {
        if (bytes) |value| try dir.dir.writeFile(io, .{ .sub_path = "priority-champions.json", .data = value });
        const service = try a.create(@import("service.zig").Service);
        defer a.destroy(service);
        service.* = .{};
        try service.initAt(io, root);
        defer service.deinit();
        try testing.expectEqualDeep(prefs, service.preferences);
        try testing.expectEqual(@as(usize, 0), service.snapshot.champion_count);
        try testing.expect(!service.snapshot.connected);
    }
}

test "failed cache writes remain retryable and unchanged data does not rewrite the file" {
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &dir.sub_path, "new-profile" });
    defer a.free(root);
    const state = try snapshot();
    defer a.destroy(state);
    var prefs: t.Preferences = .{};
    prefs.add(107);
    var saved: cache.Cache = .{};
    saved.update(&prefs, state);
    if (saved.save(a, io, root)) |_| return error.ExpectedMissingDirectory else |_| {}
    try testing.expect(saved.saved_hash == null);
    try std.Io.Dir.cwd().createDirPath(io, root);
    try saved.save(a, io, root);
    try testing.expect(saved.saved_hash != null);
    // A denied destination would fail if an unchanged snapshot tried to write.
    const absent = try std.fs.path.join(a, &.{ root, "absent" });
    defer a.free(absent);
    try saved.save(a, io, absent);
}

test "selected portrait downloads take priority and retry failures without blocking other heroes" {
    const state = try snapshot();
    defer a.destroy(state);
    var prefs: t.Preferences = .{};
    prefs.add(107);
    prefs.add(99);
    var queue: cache.PortraitQueue = .{};
    try testing.expectEqual(@as(?usize, 1), queue.next(&prefs, state, 0));
    // Rengar failed; Lux can still download immediately, ahead of Annie.
    try testing.expectEqual(@as(?usize, 2), queue.next(&prefs, state, 1));
    state.champions[2].icon_path.set("cache/lux.png");
    try testing.expect(queue.next(&prefs, state, 4999) == null);
    try testing.expectEqual(@as(?usize, 1), queue.next(&prefs, state, 5000));
    state.champions[1].icon_path.set("cache/rengar.png");
    try testing.expect(queue.next(&prefs, state, 10000) == null);
    prefs.add(1);
    try testing.expectEqual(@as(?usize, 0), queue.next(&prefs, state, 10000));
}
