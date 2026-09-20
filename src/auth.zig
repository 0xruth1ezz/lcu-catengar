const std = @import("std");
const discovery = @import("auth_discovery.zig");
pub const Credentials = discovery.Credentials;
pub const discover = discovery.discover;
pub const parse = discovery.parse;
const broker = @import("auth_broker.zig");
const win = @import("windows.zig");
const c = win.c;

/// Only an explicitly cancelled launch waits for the user's retry. A failed
/// helper/IPC connection retries automatically with backoff, independent of UI.
pub const PromptGate = struct {
    cancelled: bool = false,
    retry_at: u64 = 0,
    pub fn begin(self: *PromptGate, now: u64) bool {
        if (self.cancelled or now < self.retry_at) return false;
        self.retry_at = now + 5000;
        return true;
    }
    pub fn failed(self: *PromptGate, err: anyerror, now: u64) void {
        self.cancelled = err == error.HelperCancelled;
        self.retry_at = now + 5000;
    }
    pub fn retry(self: *PromptGate) void {
        self.* = .{};
    }
};
/// A failed connection cannot reuse an old discovery result. Even if the token
/// stays the same, one new discovery must finish before the next attempt.
pub const Recovery = struct {
    active_revision: ?u64 = null,
    after_attempt: ?u64 = null,
    retry_at: u64 = 0,
    pub fn changed(self: Recovery, identity: Identity) bool {
        return if (self.active_revision) |revision| identity.status != .ready or identity.revision != revision else false;
    }
    pub fn available(self: Recovery, identity: Identity, now: u64) bool {
        return identity.status == .ready and now >= self.retry_at and (self.after_attempt == null or identity.attempt > self.after_attempt.?);
    }
    pub fn failed(self: *Recovery, identity: Identity, now: u64) void {
        self.* = .{ .after_attempt = identity.attempt, .retry_at = now + 1000 };
    }
    pub fn connected(self: *Recovery, identity: Identity) void {
        self.* = .{ .active_revision = identity.revision };
    }
};
pub const Identity = struct {
    pub const Status = enum { starting, ready, not_running, client_starting, admin_required, failed, authorizing, permission_required, helper_missing, helper_failed };
    status: Status = .starting,
    credentials: Credentials = .{ .port = 0, .pid = 0, .token = .{} },
    revision: u64 = 0,
    attempt: u64 = 0,
    failure: ?anyerror = null,

    pub fn update(self: *Identity, status: Status, credentials: ?Credentials) void {
        const changed = self.status != status or if (credentials) |v|
            self.credentials.pid != v.pid or self.credentials.port != v.port or !std.mem.eql(u8, self.credentials.token.text(), v.token.text())
        else
            self.credentials.pid != 0;
        self.attempt += 1;
        if (changed) self.revision += 1;
        @memset(std.mem.asBytes(&self.credentials), 0);
        if (credentials) |v| self.credentials = v;
        self.status = status;
        self.failure = null;
    }
};

/// Discovery runs independently of the automation loop. A process handle detects
/// exit immediately; periodic command-line reads also detect PID/port/token changes.
pub const Watcher = struct {
    mutex: win.Mutex = .{},
    identity: Identity = .{},
    stopping: std.atomic.Value(bool) = .init(false),
    retry_helper: std.atomic.Value(bool) = .init(false),
    poke: c.HANDLE,
    shutdown: c.HANDLE,
    thread: ?std.Thread = null,

    pub fn create() !*Watcher {
        const self = try std.heap.page_allocator.create(Watcher);
        errdefer std.heap.page_allocator.destroy(self);
        const poke = c.CreateEventW(null, 0, 0, null) orelse return error.AuthWatchEvent;
        errdefer _ = c.CloseHandle(poke);
        const shutdown = c.CreateEventW(null, 1, 0, null) orelse return error.AuthWatchEvent;
        errdefer _ = c.CloseHandle(shutdown);
        self.* = .{ .poke = poke, .shutdown = shutdown };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    pub fn destroy(self: *Watcher) void {
        self.stopping.store(true, .release);
        _ = c.SetEvent(self.shutdown);
        self.refresh();
        if (self.thread) |thread| thread.join();
        _ = c.CloseHandle(self.poke);
        _ = c.CloseHandle(self.shutdown);
        @memset(std.mem.asBytes(&self.identity), 0);
        std.heap.page_allocator.destroy(self);
    }
    pub fn refresh(self: *Watcher) void {
        _ = c.SetEvent(self.poke);
    }
    pub fn requestHelper(self: *Watcher) void {
        self.retry_helper.store(true, .release);
        self.refresh();
    }
    pub fn read(self: *Watcher) Identity {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.identity;
    }
    fn update(self: *Watcher, status: Identity.Status, credentials: ?Credentials) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.identity.update(status, credentials);
    }
    fn failed(self: *Watcher, status: Identity.Status, err: anyerror) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.identity.update(status, null);
        self.identity.failure = err;
    }
    fn run(self: *Watcher) void {
        var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{ .environ = .{ .block = .global } });
        defer threaded.deinit();
        var helper: ?broker.Client = null;
        defer if (helper) |*client| client.deinit();
        var prompt: PromptGate = .{};
        var helper_error: Identity.Status = .helper_failed;
        var helper_failure: anyerror = error.HelperLaunch;
        while (!self.stopping.load(.acquire)) {
            if (self.retry_helper.swap(false, .acq_rel)) prompt.retry();
            if (helper) |*client| {
                var result = client.read(self.poke) catch |err| {
                    if (err == error.Interrupted) continue;
                    client.deinit();
                    helper = null;
                    helper_error = .helper_failed;
                    helper_failure = err;
                    prompt.failed(err, win.now());
                    self.failed(helper_error, err);
                    _ = c.WaitForSingleObject(self.poke, 3000);
                    continue;
                };
                defer @memset(std.mem.asBytes(&result), 0);
                self.update(switch (result.status) {
                    .ready => .ready,
                    .not_running => .not_running,
                    .client_starting => .client_starting,
                    .admin_required => .admin_required,
                    .failed => .failed,
                }, if (result.status == .ready) result.credentials else null);
                continue;
            }
            var credentials = discover(std.heap.page_allocator, threaded.io()) catch |err| {
                if (err == error.AdminRequired) {
                    if (!self.stopping.load(.acquire) and prompt.begin(win.now())) {
                        self.update(.authorizing, null);
                        helper = broker.Client.start(self.shutdown) catch |launch_error| {
                            if (self.stopping.load(.acquire)) return;
                            prompt.failed(launch_error, win.now());
                            helper_error = switch (launch_error) {
                                error.HelperMissing => .helper_missing,
                                error.HelperCancelled => .permission_required,
                                else => .helper_failed,
                            };
                            helper_failure = launch_error;
                            self.failed(helper_error, launch_error);
                            continue;
                        };
                        continue;
                    }
                    self.failed(helper_error, helper_failure);
                    _ = c.WaitForSingleObject(self.poke, 3000);
                    continue;
                }
                self.update(switch (err) {
                    error.ClientNotRunning => .not_running,
                    error.ClientNotReady => .client_starting,
                    else => .failed,
                }, null);
                _ = c.WaitForSingleObject(self.poke, 3000);
                continue;
            };
            defer @memset(std.mem.asBytes(&credentials), 0);
            self.update(.ready, credentials);
            const process = c.OpenProcess(c.SYNCHRONIZE, 0, credentials.pid);
            defer if (process != null) {
                _ = c.CloseHandle(process);
            };
            if (process != null) {
                const handles = [_]c.HANDLE{ self.poke, process };
                if (c.WaitForMultipleObjects(handles.len, &handles, 0, 5000) == c.WAIT_OBJECT_0 + 1) self.update(.not_running, null);
            } else _ = c.WaitForSingleObject(self.poke, 5000);
        }
    }
};
