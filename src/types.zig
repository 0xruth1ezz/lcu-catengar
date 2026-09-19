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
    always_prioritize: bool = true,
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

pub const ConnectionState = enum { connecting, waiting_client, reconnecting, authorizing, permission_required, helper_missing, helper_failed, failed };

pub const Profile = struct {
    name: Text(96) = .{},
    riot_id: Text(128) = .{},
    icon_id: ?u32 = null,
    icon_path: Text(768) = .{},
};

pub const LogKind = enum { app, connection, accept, pick };
pub const LogLevel = enum { info, success, warning, failure };
pub const LogEntry = struct {
    timestamp: Text(32) = .{},
    kind: LogKind = .app,
    level: LogLevel = .info,
    message: Text(512) = .{},
    pub fn init(kind: LogKind, level: LogLevel, message: []const u8) LogEntry {
        var entry: LogEntry = .{ .kind = kind, .level = level, .message = Text(512).init(message) };
        const c = @import("windows.zig").c;
        var time: c.SYSTEMTIME = undefined;
        c.GetLocalTime(&time);
        var buffer: [32]u8 = undefined;
        entry.timestamp.set(std.fmt.bufPrint(&buffer, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{ time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute, time.wSecond, time.wMilliseconds }) catch "时间不可用");
        return entry;
    }
    pub fn kindLabel(self: *const LogEntry) []const u8 {
        return switch (self.kind) {
            .app => "应用",
            .connection => "连接",
            .accept => "接受对局",
            .pick => "自动选取",
        };
    }
    pub fn levelLabel(self: *const LogEntry) []const u8 {
        return switch (self.level) {
            .info => "信息",
            .success => "成功",
            .warning => "提醒",
            .failure => "失败",
        };
    }
    pub fn failed(self: *const LogEntry) bool {
        return self.level == .failure;
    }
};
pub const LogSink = struct {
    context: *anyopaque,
    emit: *const fn (*anyopaque, LogEntry) void,
};

pub const Snapshot = struct {
    catalog_generation: u64 = 0,
    connected: bool = false,
    profile: Profile = .{},
    auth_retry_available: bool = false,
    connection: ConnectionState = .connecting,
    settings_error: Text(192) = .{},
    pick_supported: ?bool = null,
    pick_completed: bool = false,
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
    logs: [10]LogEntry = @splat(.{}),
    log_count: usize = 0,
    log_sink: ?LogSink = null,
    pub fn log(self: *Snapshot, message: []const u8) void {
        // Resource/settings retries can repeat on every service tick. Keep
        // those status messages quiet; actual activity events are never deduped.
        if (self.log_count > 0 and std.mem.eql(u8, self.logs[0].message.text(), message)) return;
        self.logEvent(.app, .info, message);
    }
    pub fn logEvent(self: *Snapshot, kind: LogKind, level: LogLevel, message: []const u8) void {
        const entry = LogEntry.init(kind, level, message);
        const n = @min(self.log_count, self.logs.len - 1);
        std.mem.copyBackwards(LogEntry, self.logs[1 .. n + 1], self.logs[0..n]);
        self.logs[0] = entry;
        self.log_count = @min(self.logs.len, self.log_count + 1);
        if (self.log_sink) |sink| sink.emit(sink.context, entry);
    }
};
