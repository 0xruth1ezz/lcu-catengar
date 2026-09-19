const std = @import("std");
const t = @import("types.zig");

const Entry = struct {
    id: i32 = 0,
    rank: usize = 0,
    available: bool = false,
    held: bool = false,
    attempted: bool = false,
    unconfirmed: bool = false,
    automatic: bool = false,
};
pub const Audit = struct {
    entries: [t.max_champions]Entry = @splat(.{}),
    count: usize = 0,
    current: i32 = 0,

    fn find(self: *Audit, id: i32) ?*Entry {
        for (self.entries[0..self.count]) |*entry| if (entry.id == id) return entry;
        return null;
    }
    pub fn observe(self: *Audit, prefs: *const t.Preferences, state: *const t.Snapshot, pickable: []const i32) void {
        self.current = state.current;
        for (self.entries[0..self.count]) |*entry| if (entry.id == state.current) {
            entry.held = true;
        };
        if (!prefs.auto_pick) return;
        for (prefs.ids(), 0..) |id, rank| {
            const entry = self.find(id) orelse blk: {
                if (self.count == self.entries.len) continue;
                self.entries[self.count] = .{ .id = id, .rank = rank + 1 };
                self.count += 1;
                break :blk &self.entries[self.count - 1];
            };
            entry.rank = rank + 1;
            entry.held = entry.held or id == state.current;
            entry.available = entry.available or id == state.current or std.mem.indexOfScalar(i32, state.bench[0..state.bench_count], id) != null or std.mem.indexOfScalar(i32, pickable, id) != null;
        }
    }
    pub fn attempt(self: *Audit, id: i32) void {
        if (self.find(id)) |entry| {
            entry.attempted = true;
            entry.unconfirmed = true;
        }
    }
    pub fn rejected(self: *Audit, id: i32) void {
        if (self.find(id)) |entry| entry.unconfirmed = false;
    }
    pub fn confirmed(self: *Audit, id: i32) void {
        if (self.find(id)) |entry| {
            entry.automatic = true;
            entry.held = true;
            entry.unconfirmed = false;
        }
    }
    pub fn finish(self: *Audit, state: *t.Snapshot, interrupted: bool) void {
        for (self.entries[0..self.count]) |entry| {
            const result = if (entry.automatic)
                (if (entry.id == self.current) "已自动选中，最后一次同步时持有" else "曾自动选中，后来已换出")
            else if (entry.held)
                (if (entry.id == self.current) "最后一次同步时已持有（非自动选取）" else "曾持有（非自动选取）")
            else if (entry.unconfirmed)
                "已发起请求，结果未确认"
            else if (entry.attempted)
                "未抢到，请求未成功"
            else if (entry.available)
                "出现过可用机会，未提交选取"
            else
                "未发现可用机会";
            var buffer: [512]u8 = undefined;
            state.logEvent(.pick, .info, std.fmt.bufPrint(&buffer, "{s} · 顺位 {d} · {s}（{d}）：{s}", .{ if (interrupted) "记录截至连接中断" else "本轮选人结果", entry.rank, name(state, entry.id), entry.id, result }) catch "选人记录生成失败");
        }
        self.* = .{};
    }
};
pub fn name(state: *const t.Snapshot, id: i32) []const u8 {
    for (state.champions[0..state.champion_count]) |*champion| if (champion.id == id) return champion.name.text();
    return "英雄";
}
