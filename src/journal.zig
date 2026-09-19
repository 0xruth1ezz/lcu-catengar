const std = @import("std");
const t = @import("types.zig");
const win = @import("windows.zig");
const a = std.heap.page_allocator;
pub const page_size = 20;

const Wire = struct { timestamp: []const u8, kind: t.LogKind, level: t.LogLevel, message: []const u8 };
pub fn encode(allocator: std.mem.Allocator, entry: t.LogEntry) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, Wire{ .timestamp = entry.timestamp.text(), .kind = entry.kind, .level = entry.level, .message = entry.message.text() }, .{});
}
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !t.LogEntry {
    const parsed = try std.json.parseFromSlice(Wire, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const v = parsed.value;
    if (v.timestamp.len > 32 or v.message.len > 512) return error.InvalidLogEntry;
    return .{ .timestamp = t.Text(32).init(v.timestamp), .kind = v.kind, .level = v.level, .message = t.Text(512).init(v.message) };
}

pub const Page = struct {
    entries: [page_size]t.LogEntry = @splat(.{}),
    count: usize = 0,
    total: usize = 0,
    start: usize = 0,
    end: usize = 0,
    live: bool = true,
    loading: bool = true,
    clearing: bool = false,
    revision: u64 = 0,
    clear_revision: u64 = 0,
    error_message: t.Text(192) = .{},
    directory_error: t.Text(192) = .{},
};

/// The file remains human-readable JSON Lines. Only offsets stay in memory;
/// every historical entry is reachable without loading the entire history.
pub const Store = struct {
    file: std.Io.File,
    offsets: std.ArrayList(u64) = .empty,
    length: u64 = 0,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Store {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false });
        var self: Store = .{ .file = file, .allocator = allocator };
        errdefer self.close(io);
        self.length = try file.length(io);
        var buffer: [64 * 1024]u8 = undefined;
        var position: u64 = 0;
        var line_start: u64 = 0;
        while (position < self.length) {
            const count = try file.readPositionalAll(io, buffer[0..@min(buffer.len, self.length - position)], position);
            if (count == 0) return error.UnexpectedEndOfFile;
            for (buffer[0..count], 0..) |byte, index| if (byte == '\n') {
                try self.offsets.append(allocator, line_start);
                line_start = position + index + 1;
            };
            position += count;
        }
        if (line_start < self.length) {
            // Preserve an interrupted tail as its own visible record. A new
            // append must never concatenate onto it and corrupt the next entry.
            try self.offsets.append(allocator, line_start);
            try file.writePositionalAll(io, "\n", self.length);
            self.length += 1;
        }
        return self;
    }
    pub fn close(self: *Store, io: std.Io) void {
        self.file.close(io);
        self.offsets.deinit(self.allocator);
    }
    pub fn append(self: *Store, io: std.Io, entry: t.LogEntry) !void {
        const json = try encode(self.allocator, entry);
        defer self.allocator.free(json);
        try self.offsets.ensureUnusedCapacity(self.allocator, 1);
        errdefer self.file.setLength(io, self.length) catch {};
        try self.file.writePositionalAll(io, json, self.length);
        try self.file.writePositionalAll(io, "\n", self.length + json.len);
        try self.file.sync(io);
        self.offsets.appendAssumeCapacity(self.length);
        self.length += json.len + 1;
    }
    pub fn clear(self: *Store, io: std.Io) !void {
        try self.file.setLength(io, 0);
        self.length = 0;
        self.offsets.clearRetainingCapacity();
        try self.file.sync(io);
    }
    pub fn readPage(self: *Store, io: std.Io, before: ?usize) !Page {
        var page: Page = .{ .total = self.offsets.items.len, .live = before == null, .loading = false };
        page.end = @min(before orelse page.total, page.total);
        page.start = page.end -| page_size;
        page.count = page.end - page.start;
        for (page.entries[0..page.count], 0..) |*entry, row| {
            const index = page.end - row - 1;
            const offset = self.offsets.items[index];
            const end = if (index + 1 < page.total) self.offsets.items[index + 1] else self.length;
            var buffer: [4096]u8 = undefined;
            const length = end - offset;
            entry.* = .{ .level = .warning, .message = t.Text(512).init("这条记录格式损坏，原始内容仍保留在日志文件中。") };
            if (length > buffer.len) continue;
            const count = try self.file.readPositionalAll(io, buffer[0..@intCast(length)], offset);
            entry.* = decode(self.allocator, buffer[0..count]) catch continue;
        }
        return page;
    }
};

const Command = struct { epoch: u64, entry: ?t.LogEntry = null };
pub const Worker = struct {
    mutex: win.Mutex = .{},
    queue: std.ArrayList(Command) = .empty,
    epoch: u64 = 0,
    before: ?usize = null,
    refresh: bool = true,
    open_requested: bool = false,
    page: Page = .{},
    directory: []const u8,
    path: []const u8,
    wake: win.c.HANDLE,
    stopping: bool = false,
    thread: ?std.Thread = null,
    notify: *const fn () bool,

    pub fn create(root: []const u8, notify: *const fn () bool) !*Worker {
        const self = try a.create(Worker);
        errdefer a.destroy(self);
        const directory = try std.fs.path.join(a, &.{ root, "logs" });
        errdefer a.free(directory);
        const path = try std.fs.path.join(a, &.{ directory, "activity.jsonl" });
        errdefer a.free(path);
        const wake = win.c.CreateEventW(null, 0, 0, null) orelse return error.LogWorkerEvent;
        errdefer _ = win.c.CloseHandle(wake);
        self.* = .{ .directory = directory, .path = path, .wake = wake, .notify = notify };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    pub fn destroy(self: *Worker) void {
        self.mutex.lock();
        self.stopping = true;
        self.mutex.unlock();
        _ = win.c.SetEvent(self.wake);
        if (self.thread) |thread| thread.join();
        self.queue.deinit(a);
        _ = win.c.CloseHandle(self.wake);
        a.free(self.path);
        a.free(self.directory);
        a.destroy(self);
    }
    pub fn sink(self: *Worker) t.LogSink {
        return .{ .context = self, .emit = emit };
    }
    fn emit(context: *anyopaque, entry: t.LogEntry) void {
        const self: *Worker = @ptrCast(@alignCast(context));
        self.mutex.lock();
        self.queue.append(a, .{ .epoch = self.epoch, .entry = entry }) catch {
            self.page.error_message.set("日志缓冲区内存不足，部分记录未能保存。");
        };
        self.mutex.unlock();
        _ = win.c.SetEvent(self.wake);
    }
    pub fn read(self: *Worker, page: *Page) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        page.* = self.page;
    }
    pub fn request(self: *Worker, before: ?usize) void {
        self.mutex.lock();
        self.before = before;
        self.refresh = true;
        self.page.loading = true;
        self.mutex.unlock();
        _ = win.c.SetEvent(self.wake);
    }
    pub fn clear(self: *Worker) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // A clear is a barrier: earlier queued events are covered by the
        // deletion, later events retain their order and continue recording.
        self.queue.ensureUnusedCapacity(a, 1) catch {
            self.page.error_message.set("无法开始清空日志，请重试。");
            _ = self.notify();
            return;
        };
        self.epoch +%= 1;
        self.queue.clearRetainingCapacity();
        self.queue.appendAssumeCapacity(.{ .epoch = self.epoch });
        self.page.clearing = true;
        _ = win.c.SetEvent(self.wake);
    }
    pub fn openDirectory(self: *Worker) void {
        self.mutex.lock();
        self.open_requested = true;
        self.mutex.unlock();
        _ = win.c.SetEvent(self.wake);
    }
    fn report(self: *Worker, message: []const u8) void {
        self.mutex.lock();
        self.page.error_message.set(message);
        self.page.loading = false;
        self.page.clearing = false;
        self.mutex.unlock();
        _ = self.notify();
    }
    fn run(self: *Worker) void {
        var threaded: std.Io.Threaded = .init(a, .{});
        defer threaded.deinit();
        const io = threaded.io();
        var store: ?Store = null;
        defer if (store) |*s| s.close(io);
        while (true) {
            self.mutex.lock();
            const stopping = self.stopping;
            const empty = self.queue.items.len == 0;
            self.mutex.unlock();
            if (stopping and empty) break;
            if (store == null) {
                std.Io.Dir.cwd().createDirPath(io, self.directory) catch {
                    self.report("无法创建日志目录，请检查目录权限。记录暂存在内存中，将自动重试。");
                    if (stopping) break;
                    _ = win.c.WaitForSingleObject(self.wake, 5000);
                    continue;
                };
                store = Store.open(a, io, self.path) catch {
                    self.report("无法打开日志文件，请检查目录权限或文件占用。记录暂存在内存中，将自动重试。");
                    if (stopping) break;
                    _ = win.c.WaitForSingleObject(self.wake, 5000);
                    continue;
                };
            }
            self.mutex.lock();
            const command: ?Command = if (self.queue.items.len > 0) self.queue.orderedRemove(0) else null;
            const open_requested = self.open_requested;
            self.open_requested = false;
            const refresh = self.refresh or open_requested;
            self.refresh = false;
            var before = self.before;
            self.mutex.unlock();
            if (open_requested) {
                const open_error: []const u8 = if (win.revealFile(self.path)) |_| "" else |err| switch (err) {
                    error.LogPathUnavailable => "日志文件暂不可访问，请稍后重试「打开日志目录」。",
                    else => "无法打开资源管理器，请稍后重试「打开日志目录」。",
                };
                self.mutex.lock();
                self.page.directory_error.set(open_error);
                self.mutex.unlock();
            }
            if (command) |cmd| {
                const result = if (cmd.entry) |entry| store.?.append(io, entry) else store.?.clear(io);
                result catch {
                    self.mutex.lock();
                    if (cmd.epoch == self.epoch) self.queue.insert(a, 0, cmd) catch {};
                    self.mutex.unlock();
                    self.report("日志文件写入失败，请检查磁盘空间或权限。尚未保存的记录将在后台重试。");
                    if (stopping) break;
                    _ = win.c.WaitForSingleObject(self.wake, 5000);
                    continue;
                };
                if (cmd.entry == null) {
                    self.mutex.lock();
                    self.before = null;
                    before = null;
                    self.page.clear_revision +%= 1;
                    self.page.clearing = false;
                    self.mutex.unlock();
                }
            }
            if (command != null or refresh) {
                var page = store.?.readPage(io, before) catch {
                    self.report("无法读取这页日志，请刷新重试；已保存的日志仍在本机。");
                    continue;
                };
                self.mutex.lock();
                page.revision = self.page.revision +% 1;
                page.clear_revision = self.page.clear_revision;
                page.clearing = self.page.clearing;
                page.directory_error = self.page.directory_error;
                if (self.refresh) page.loading = true;
                self.page = page;
                self.mutex.unlock();
                _ = self.notify();
            } else if (!stopping) _ = win.c.WaitForSingleObject(self.wake, win.c.INFINITE);
        }
    }
};
