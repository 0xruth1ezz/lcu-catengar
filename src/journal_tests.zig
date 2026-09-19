const std = @import("std");
const testing = std.testing;
const a = testing.allocator;
const io = testing.io;
const j = @import("journal.zig");
const t = @import("types.zig");
const win = @import("windows.zig");

fn record(index: usize) t.LogEntry {
    var buffer: [80]u8 = undefined;
    return t.LogEntry.init(.pick, .info, std.fmt.bufPrint(&buffer, "顺位英雄记录 {d}", .{index}) catch unreachable);
}
fn notify() bool {
    return true;
}
fn waitFor(worker: *j.Worker, count: usize, cleared: bool) !j.Page {
    for (0..500) |_| {
        var page: j.Page = .{};
        worker.read(&page);
        if (!page.loading and !page.clearing and page.total == count and (!cleared or page.clear_revision > 0)) return page;
        win.c.Sleep(10);
    }
    return error.LogWorkerTimeout;
}

test "timestamped log records preserve Chinese text and JSON escapes" {
    const entry = t.LogEntry.init(.pick, .failure, "未抢到：疾风剑豪 \"请求失败\"\n第二行");
    try testing.expectEqual(@as(usize, 23), entry.timestamp.len);
    const encoded = try j.encode(a, entry);
    defer a.free(encoded);
    try testing.expect(std.mem.indexOfScalar(u8, encoded, '\n') == null);
    try testing.expectEqualDeep(entry, try j.decode(a, encoded));
    try testing.expectError(error.SyntaxError, j.decode(a, "broken record"));
}

test "Explorer receives an existing absolute Unicode path with native separators" {
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/日志 空格.jsonl", .{dir.sub_path});
    defer a.free(path);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    file.close(io);
    const wide = try win.shellPath(a, path);
    defer a.free(wide);
    const resolved = try std.unicode.utf16LeToUtf8Alloc(a, wide);
    defer a.free(resolved);
    try testing.expect(std.fs.path.isAbsolute(resolved));
    try testing.expect(std.mem.indexOfScalar(u8, resolved, '/') == null);
    try testing.expect(std.mem.endsWith(u8, resolved, "\\日志 空格.jsonl"));
    try testing.expectError(error.InvalidShellPath, win.shellPath(a, ""));
    try testing.expectError(error.InvalidShellPath, win.shellPath(a, "path\x00suffix"));
    try testing.expectError(error.LogPathUnavailable, win.shellPath(a, ".zig-cache/nonexistent-catengar-folder/file.jsonl"));
}

test "all log history survives reopening and historical pages stay anchored as new events arrive" {
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    const path = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &dir.sub_path, "activity.jsonl" });
    defer a.free(path);
    var store = try j.Store.open(a, io, path);
    var closed = false;
    defer if (!closed) store.close(io);
    for (0..65) |i| try store.append(io, record(i));
    const latest = try store.readPage(io, null);
    try testing.expectEqual(@as(usize, 65), latest.total);
    try testing.expectEqualStrings(record(64).message.text(), latest.entries[0].message.text());
    const older = try store.readPage(io, latest.start);
    try store.append(io, record(65));
    const anchored = try store.readPage(io, latest.start);
    try testing.expectEqual(@as(usize, 66), anchored.total);
    try testing.expectEqualDeep(older.entries, anchored.entries);
    store.close(io);
    closed = true;
    var reopened = try j.Store.open(a, io, path);
    defer reopened.close(io);
    var before: ?usize = null;
    var visited: usize = 0;
    while (true) {
        const page = try reopened.readPage(io, before);
        for (page.entries[0..page.count]) |entry| {
            try testing.expectEqualStrings(record(65 - visited).message.text(), entry.message.text());
            visited += 1;
        }
        if (page.start == 0) break;
        before = page.start;
    }
    try testing.expectEqual(@as(usize, 66), visited);
    try reopened.clear(io);
    try testing.expectEqual(@as(u64, 0), try reopened.file.length(io));
    try testing.expectEqual(@as(usize, 0), (try reopened.readPage(io, null)).total);
    try reopened.append(io, record(99));
    try testing.expectEqualStrings(record(99).message.text(), (try reopened.readPage(io, null)).entries[0].message.text());
}

test "interrupted log tails remain visible and never corrupt the next record" {
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    const path = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &dir.sub_path, "activity.jsonl" });
    defer a.free(path);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    try file.writeStreamingAll(io, "{\"interrupted\":");
    file.close(io);
    var store = try j.Store.open(a, io, path);
    defer store.close(io);
    try store.append(io, record(1));
    const page = try store.readPage(io, null);
    try testing.expectEqual(@as(usize, 2), page.total);
    try testing.expectEqualStrings(record(1).message.text(), page.entries[0].message.text());
    try testing.expectEqual(t.LogLevel.warning, page.entries[1].level);
    try testing.expect(std.mem.indexOf(u8, page.entries[1].message.text(), "格式损坏") != null);
}

test "background clear is a barrier and shutdown flushes all subsequent records" {
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &dir.sub_path });
    defer a.free(root);
    const worker = try j.Worker.create(root, notify);
    var destroyed = false;
    defer if (!destroyed) worker.destroy();
    const sink = worker.sink();
    for (0..50) |i| sink.emit(sink.context, record(i));
    worker.clear();
    sink.emit(sink.context, record(999));
    const page = try waitFor(worker, 1, true);
    try testing.expectEqualStrings(record(999).message.text(), page.entries[0].message.text());
    for (0..65) |i| sink.emit(sink.context, record(i));
    worker.destroy();
    destroyed = true;
    const path = try std.fs.path.join(a, &.{ root, "logs", "activity.jsonl" });
    defer a.free(path);
    var store = try j.Store.open(a, io, path);
    defer store.close(io);
    const saved = try store.readPage(io, null);
    try testing.expectEqual(@as(usize, 66), saved.total);
    try testing.expectEqualStrings(record(64).message.text(), saved.entries[0].message.text());
    try testing.expectEqualStrings(record(999).message.text(), (try store.readPage(io, 1)).entries[0].message.text());
}

test "unwritable log directory exposes an error without blocking shutdown" {
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &dir.sub_path });
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "logs" });
    defer a.free(path);
    const blocker = try std.Io.Dir.cwd().createFile(io, path, .{});
    blocker.close(io);
    const worker = try j.Worker.create(root, notify);
    defer worker.destroy();
    const sink = worker.sink();
    sink.emit(sink.context, record(1));
    var page: j.Page = .{};
    for (0..500) |_| {
        worker.read(&page);
        if (page.error_message.len > 0) break;
        win.c.Sleep(10);
    }
    try testing.expect(page.error_message.len > 0);
    try testing.expectEqual(@as(usize, 0), page.total);
}

test "selection audit separates confirmed unconfirmed rejected and unavailable heroes" {
    const state = try a.create(t.Snapshot);
    defer a.destroy(state);
    state.* = .{};
    var prefs: t.Preferences = .{ .auto_pick = true };
    for ([_]i32{ 1, 2, 3, 4, 5, 6 }) |id| prefs.add(id);
    state.current = 4;
    state.bench[0] = 5;
    state.bench_count = 1;
    var audit: @import("pick_audit.zig").Audit = .{};
    audit.observe(&prefs, state, &.{});
    audit.attempt(1);
    audit.confirmed(1);
    audit.attempt(2);
    audit.attempt(3);
    audit.rejected(3);
    state.current = 1;
    audit.observe(&prefs, state, &.{});
    audit.finish(state, false);
    try testing.expectEqual(@as(usize, 6), state.log_count);
    for ([_][]const u8{ "未发现可用机会", "出现过可用机会，未提交选取", "曾持有（非自动选取）", "未抢到，请求未成功", "已发起请求，结果未确认", "已自动选中，最后一次同步时持有" }, 0..) |expected, index| {
        try testing.expect(std.mem.indexOf(u8, state.logs[index].message.text(), expected) != null);
    }
    audit.finish(state, false);
    try testing.expectEqual(@as(usize, 6), state.log_count);
    audit.observe(&prefs, state, &.{});
    audit.finish(state, true);
    try testing.expect(std.mem.startsWith(u8, state.logs[0].message.text(), "记录截至连接中断"));
}
