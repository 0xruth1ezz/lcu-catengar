const std = @import("std");
const win = @import("windows.zig");
const c = win.c;
const lcu = @import("lcu.zig");
const logic = @import("logic.zig");
const a = std.heap.page_allocator;

pub const paths = [_][]const u8{
    "/lol-gameflow/v1/gameflow-phase",
    "/lol-gameflow/v1/session",
    "/lol-matchmaking/v1/ready-check",
    "/lol-champ-select/v1/session",
    "/lol-champ-select/v1/pickable-champion-ids",
    @import("profile.zig").endpoint,
};
pub const Slot = enum(usize) { phase, game, ready, selection, pickable, summoner };
const Entry = struct { body: ?[]u8 = null, status: u32 = 404, revision: u64 = 0 };

/// Only the subscribed resources are retained. Each replacement owns its
/// bytes, so receiver frames cannot outlive or alias the cache accidentally.
pub const Cache = struct {
    mutex: win.Mutex = .{},
    entries: [paths.len]Entry = @splat(.{}),
    generation: u64 = 0,
    transitions: u64 = 0,
    phase: @import("types.zig").Text(64) = .{},
    pub fn index(path: []const u8) ?usize {
        for (paths, 0..) |p, i| if (std.mem.eql(u8, p, path)) return i;
        return null;
    }
    pub fn deinit(self: *Cache) void {
        for (&self.entries) |*entry| if (entry.body) |bytes| a.free(bytes);
    }
    pub fn invalidate(self: *Cache) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (0..paths.len) |i| self.replace(i, 404, null);
        self.phase.set("");
        self.transitions += 1;
    }
    pub fn version(self: *Cache, i: usize) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.entries[i].revision;
    }
    pub fn phaseVersion(self: *Cache) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.transitions;
    }
    fn replace(self: *Cache, i: usize, status: u32, owned: ?[]u8) void {
        if (self.entries[i].body) |old| a.free(old);
        self.generation += 1;
        self.entries[i] = .{ .status = status, .body = owned, .revision = self.generation };
    }
    fn changePhase(self: *Cache, data: std.json.Value) void {
        const phase = logic.str(data);
        if (std.mem.eql(u8, self.phase.text(), phase)) return;
        self.phase.set(phase);
        self.transitions += 1;
        if (!logic.eql(data, "ReadyCheck")) self.replace(@intFromEnum(Slot.ready), 404, null);
        if (!logic.eql(data, "ChampSelect")) {
            self.replace(@intFromEnum(Slot.selection), 404, null);
            self.replace(@intFromEnum(Slot.pickable), 404, null);
        }
        // Never carry an earlier ARAM queue into the next match. A fresh game
        // event may precede the phase event, so preserve it only if phases agree.
        const game = self.entries[@intFromEnum(Slot.game)].body orelse return;
        const parsed = std.json.parseFromSlice(std.json.Value, a, game, .{}) catch {
            self.replace(@intFromEnum(Slot.game), 404, null);
            return;
        };
        const matches = logic.eql(logic.get(parsed.value, "phase"), phase);
        parsed.deinit();
        if (!matches) self.replace(@intFromEnum(Slot.game), 404, null);
    }
    pub fn seed(self: *Cache, i: usize, revision: u64, response: lcu.Response) !void {
        const owned = try a.dupe(u8, response.body);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.entries[i].revision != revision) {
            a.free(owned);
            return;
        }
        if (i == @intFromEnum(Slot.phase)) {
            const parsed = std.json.parseFromSlice(std.json.Value, a, response.body, .{}) catch {
                a.free(owned);
                return error.InvalidPhase;
            };
            defer parsed.deinit();
            self.changePhase(parsed.value);
        }
        self.replace(i, response.status, owned);
    }
    pub fn read(self: *Cache, allocator: std.mem.Allocator, i: usize) !lcu.Response {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.entries[i];
        return .{ .status = entry.status, .body = try allocator.dupe(u8, entry.body orelse "null") };
    }
    pub fn apply(self: *Cache, bytes: []const u8) !bool {
        // Some LCU builds send an empty data message just after upgrading.
        if (std.mem.trim(u8, bytes, " \r\n\t").len == 0) return false;
        const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
        defer parsed.deinit();
        const message = logic.items(parsed.value);
        // LCU uses the WAMP v1 EVENT frame [8, topic, {uri,eventType,data}].
        if (message.len != 3 or logic.integer(message[0]) != 8 or !std.mem.startsWith(u8, logic.str(message[1]), "OnJsonApiEvent")) return false;
        const event = message[2];
        const i = index(logic.str(logic.get(event, "uri"))) orelse return false;
        const kind = logic.str(logic.get(event, "eventType"));
        const deleted = std.mem.eql(u8, kind, "Delete");
        if (!deleted and !std.mem.eql(u8, kind, "Update") and !std.mem.eql(u8, kind, "Create")) return false;
        const data = logic.get(event, "data");
        const owned = if (deleted) null else try std.json.Stringify.valueAlloc(a, data, .{});
        self.mutex.lock();
        defer self.mutex.unlock();
        if (i == @intFromEnum(Slot.phase)) {
            self.changePhase(if (deleted) .null else data);
        }
        self.replace(i, if (deleted) 404 else 200, owned);
        return true;
    }
    /// Subscribe first, then seed. Events received during a REST request win.
    pub fn health(self: *Cache, temp: std.mem.Allocator, rest: anytype) !void {
        const revision = self.version(0);
        const response = try rest.request(temp, "GET", paths[0], "");
        try response.authenticated();
        if (!response.ok()) return error.PhaseUnavailable;
        try self.seed(0, revision, response);
    }
    pub fn sync(self: *Cache, temp: std.mem.Allocator, rest: anytype, missing_only: bool) !void {
        for (paths, 0..) |path, i| {
            self.mutex.lock();
            const revision = self.entries[i].revision;
            const present = self.entries[i].status == 200;
            self.mutex.unlock();
            if (missing_only and present) continue;
            const response = try rest.request(temp, "GET", path, "");
            if (response.status == 401 or response.status == 403) return error.AuthenticationExpired;
            if (i == 0 and !response.ok()) return error.PhaseUnavailable;
            try self.seed(i, revision, response);
        }
    }
};

pub const Stream = struct {
    socket: *@import("socket.zig").Socket,
    cache: Cache = .{},
    alive: std.atomic.Value(bool) = .init(true),
    failure: std.atomic.Value(u32) = .init(0),
    received: std.atomic.Value(u64) = .init(0),
    updates: std.atomic.Value(u64) = .init(0),
    parse_error: @import("types.zig").Text(64) = .{},
    invalid_length: usize = 0,
    boundary: [2]u8 = .{ 0, 0 },
    stopping: std.atomic.Value(bool) = .init(false),
    wake: c.HANDLE,
    thread: ?std.Thread = null,
    pub fn create(rest: *lcu.Client) !*Stream {
        const self = try a.create(Stream);
        errdefer a.destroy(self);
        const socket = try rest.webSocket();
        errdefer socket.destroy();
        const wake = c.CreateEventW(null, 0, 0, null) orelse return error.StreamEvent;
        errdefer _ = c.CloseHandle(wake);
        self.* = .{ .socket = socket, .wake = wake };
        // Specific subscriptions avoid decoding the client's unrelated events.
        for (paths) |path| {
            var buffer: [256]u8 = undefined;
            const topic = try std.fmt.bufPrint(&buffer, "[5,\"OnJsonApiEvent{s}\"]", .{path});
            for (topic) |*ch| if (ch.* == '/') {
                ch.* = '_';
            };
            try socket.send(topic);
        }
        self.thread = try std.Thread.spawn(.{}, receive, .{self});
        return self;
    }
    pub fn destroy(self: *Stream) void {
        self.stopping.store(true, .release);
        self.socket.cancel();
        if (self.thread) |thread| thread.join();
        self.socket.destroy();
        _ = c.CloseHandle(self.wake);
        self.cache.deinit();
        a.destroy(self);
    }
    pub fn wait(self: *Stream, ms: u32) void {
        _ = c.WaitForSingleObject(self.wake, ms);
    }
    fn receive(self: *Stream) void {
        defer {
            self.cache.invalidate();
            self.alive.store(false, .release);
            _ = c.SetEvent(self.wake);
        }
        var message: std.ArrayList(u8) = .empty;
        defer message.deinit(a);
        while (!self.stopping.load(.acquire)) {
            const bytes = self.socket.receive() catch {
                const failure = self.socket.failure.load(.acquire);
                self.failure.store(if (failure != 0) failure else 1006, .release);
                return;
            };
            const kind = self.socket.kind;
            if (kind == c.WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE) {
                self.failure.store(1000, .release);
                return;
            }
            if (message.items.len + bytes.len > 2 * 1024 * 1024) {
                self.failure.store(1009, .release);
                return;
            }
            message.appendSlice(a, bytes) catch return;
            if (kind == c.WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE or kind == c.WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE) {
                _ = self.received.fetchAdd(1, .acq_rel);
                if (self.cache.apply(message.items) catch |err| {
                    self.parse_error.set(@errorName(err));
                    self.invalid_length = message.items.len;
                    if (message.items.len > 0) self.boundary = .{ message.items[0], message.items[message.items.len - 1] };
                    self.failure.store(1007, .release);
                    return;
                }) {
                    _ = self.updates.fetchAdd(1, .acq_rel);
                    _ = c.SetEvent(self.wake);
                }
                message.clearRetainingCapacity();
            }
        }
    }
};

/// Automation reads cached WS resources; writes still go straight to REST.
pub const CachedClient = struct {
    rest: *lcu.Client,
    cache: *Cache,
    revision: ?u64 = null,
    pub fn request(self: *CachedClient, allocator: std.mem.Allocator, method: []const u8, path: []const u8, body: []const u8) !lcu.Response {
        if (std.mem.eql(u8, method, "GET")) {
            if (self.revision == null) {
                self.cache.mutex.lock();
                self.revision = self.cache.generation;
                self.cache.mutex.unlock();
            }
            const i = Cache.index(path) orelse return error.UnsubscribedResource;
            return self.cache.read(allocator, i);
        }
        self.cache.mutex.lock();
        const fresh = self.revision != null and self.revision.? == self.cache.generation;
        self.cache.mutex.unlock();
        if (!fresh) return .{ .status = 409, .body = "null" };
        return self.rest.request(allocator, method, path, body);
    }
};
