const std = @import("std");

pub fn Text(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = @splat(0),
        len: usize = 0,
        pub fn set(self: *@This(), value: []const u8) void {
            self.len = @min(capacity, value.len);
            while (self.len > 0 and !std.unicode.utf8ValidateSlice(value[0..self.len])) self.len -= 1;
            @memcpy(self.bytes[0..self.len], value[0..self.len]);
        }
        pub fn text(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
        pub fn init(value: []const u8) @This() {
            var result: @This() = .{};
            result.set(value);
            return result;
        }
    };
}

pub const max_champions = 256;
pub const max_priority = 32;
pub const Preferences = struct {
    theme: @import("theme.zig").Preset = @import("theme.zig").default_preset,
    auto_accept: bool = false,
    auto_pick: bool = false,
    priority: [max_priority]i32 = @splat(0),
    count: usize = 0,
    pub fn ids(self: *const Preferences) []const i32 {
        return self.priority[0..@min(self.count, max_priority)];
    }
    pub fn rank(self: *const Preferences, id: i32) usize {
        for (self.ids(), 0..) |value, index| {
            if (id == value) return index;
        }
        return max_priority;
    }
    pub fn add(self: *Preferences, id: i32) void {
        if (id <= 0 or self.count >= max_priority or self.rank(id) < max_priority) return;
        self.priority[self.count] = id;
        self.count += 1;
    }
    pub fn remove(self: *Preferences, id: i32) void {
        const index = self.rank(id);
        if (index >= self.count) return;
        std.mem.copyForwards(i32, self.priority[index .. self.count - 1], self.priority[index + 1 .. self.count]);
        self.count -= 1;
        self.priority[self.count] = 0;
    }
    pub fn move(self: *Preferences, id: i32, up: bool) void {
        const i = self.rank(id);
        if (i >= self.count or (up and i == 0) or (!up and i + 1 >= self.count)) return;
        std.mem.swap(i32, &self.priority[i], &self.priority[if (up) i - 1 else i + 1]);
    }
};

pub const Champion = struct {
    id: i32 = 0,
    name: Text(96) = .{},
    alias: Text(64) = .{},
    asset: Text(256) = .{},
    icon_path: Text(768) = .{},
};

pub const Snapshot = struct {
    catalog_generation: u64 = 0,
    connected: bool = false,
    auth_retry_available: bool = false,
    websocket: bool = false,
    status: Text(192) = Text(192).init("正在寻找 League 客户端…"),
    phase: Text(64) = Text(64).init("未连接"),
    queue_id: i32 = 0,
    current: i32 = 0,
    bench: [64]i32 = @splat(0),
    bench_count: usize = 0,
    champions: [max_champions]Champion = @splat(.{}),
    champion_count: usize = 0,
    perk_count: usize = 0,
    style_count: usize = 0,
    icon_count: usize = 0,
    accepted: usize = 0,
    swapped: usize = 0,
    last_pick_name: Text(96) = .{},
    logs: [10]Text(192) = @splat(.{}),
    log_count: usize = 0,
    pub fn log(self: *Snapshot, message: []const u8) void {
        if (self.log_count > 0 and std.mem.eql(u8, self.logs[0].text(), message)) return;
        const n = @min(self.log_count, self.logs.len - 1);
        std.mem.copyBackwards(Text(192), self.logs[1 .. n + 1], self.logs[0..n]);
        self.logs[0].set(message);
        self.log_count = @min(self.logs.len, self.log_count + 1);
    }
};
