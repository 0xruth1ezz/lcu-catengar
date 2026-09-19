const std = @import("std");
const t = @import("types.zig");

pub const duration_ms = 4500;
pub const Message = struct {
    is_update: bool = false,
    title: t.Text(48) = .{},
    body: t.Text(160) = .{},
};

/// Snapshot counters survive connection changes. Only a NEW successful
/// action enters the queue; routine WS updates never re-show a toast.
pub const State = struct {
    messages: [4]Message = @splat(.{}),
    count: usize = 0,
    accepted: usize = 0,
    swapped: usize = 0,
    deadline: u64 = 0,

    pub fn updateAvailable(self: *State, version: []const u8, now: u64) void {
        var buffer: [160]u8 = undefined;
        self.push(.{
            .is_update = true,
            .title = t.Text(48).init("发现新版本"),
            .body = t.Text(160).init(std.fmt.bufPrint(&buffer, "v{s} 已发布，可在设置中更新并重启。", .{version}) catch "可在设置中更新并重启。"),
        }, now);
    }

    pub fn observe(self: *State, snapshot: *const t.Snapshot, now: u64) void {
        if (snapshot.accepted > self.accepted) self.push(.{
            .title = t.Text(48).init("自动接受成功"),
            .body = t.Text(160).init("已接受对局，等待其他玩家确认。"),
        }, now);
        if (snapshot.swapped > self.swapped) {
            var buffer: [160]u8 = undefined;
            const name = if (snapshot.last_pick_name.len > 0) snapshot.last_pick_name.text() else "优先英雄";
            self.push(.{
                .title = t.Text(48).init("抢英雄成功"),
                .body = t.Text(160).init(std.fmt.bufPrint(&buffer, "已选中 {s}，客户端已确认。", .{name}) catch "英雄选择已由客户端确认。"),
            }, now);
        }
        self.accepted = snapshot.accepted;
        self.swapped = snapshot.swapped;
    }

    fn push(self: *State, message: Message, now: u64) void {
        // Preserve the visible toast; keep the newest pending results
        // if unusually many actions arrive while the user is away.
        if (self.count == self.messages.len) {
            std.mem.copyForwards(Message, self.messages[1 .. self.count - 1], self.messages[2..self.count]);
            self.count -= 1;
        }
        self.messages[self.count] = message;
        if (self.count == 0) self.deadline = now + duration_ms;
        self.count += 1;
    }

    pub fn dismiss(self: *State, now: u64) void {
        if (self.count == 0) return;
        std.mem.copyForwards(Message, self.messages[0 .. self.count - 1], self.messages[1..self.count]);
        self.count -= 1;
        self.deadline = if (self.count > 0) now + duration_ms else 0;
    }

    pub fn expire(self: *State, now: u64) void {
        if (self.count > 0 and now >= self.deadline) self.dismiss(now);
    }
};
