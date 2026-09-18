const std = @import("std");
const types = @import("types.zig");
pub const Credentials = struct { port: u16, token: types.Text(256), pid: u32 };

// stdout is a private pipe to this process. Never print it, store it, or pass the
// token in a subsequent command line. The powershell child has no visible window.
const discovery_script =
    \\$ErrorActionPreference='Stop'; [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
    \\try { $ps=@(Get-CimInstance Win32_Process -Filter "Name='LeagueClientUx.exe'" -OperationTimeoutSec 3) } catch { exit 13 }
    \\if ($ps.Count -eq 0) { exit 2 }
    \\foreach ($p in ($ps | Sort-Object CreationDate -Descending)) {
    \\  if (!$p.CommandLine) { continue }
    \\  $port=[regex]::Match($p.CommandLine,'--app-port[= ]+"?(\d+)')
    \\  $token=[regex]::Match($p.CommandLine,'--remoting-auth-token[= ]+"?([^\s"]+)')
    \\  if ($port.Success -and $token.Success) {
    \\    @{port=[int]$port.Groups[1].Value;token=$token.Groups[1].Value;pid=$p.ProcessId} | ConvertTo-Json -Compress
    \\    exit 0
    \\  }
    \\}
    \\exit 13
;

pub fn discover(allocator: std.mem.Allocator, io: std.Io) !Credentials {
    const output = try std.process.run(allocator, io, .{
        .argv = &.{ "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", discovery_script },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .create_no_window = true,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(8), .clock = .awake } },
    });
    defer {
        @memset(output.stdout, 0);
        allocator.free(output.stdout);
        allocator.free(output.stderr);
    }
    switch (output.term) {
        .exited => |code| switch (code) {
            0 => {},
            2 => return error.ClientNotRunning,
            13 => return error.AdminRequired,
            else => return error.DiscoveryFailed,
        },
        else => return error.DiscoveryFailed,
    }
    return parse(allocator, output.stdout);
}
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Credentials {
    const Wire = struct { port: u16, token: []const u8, pid: u32 };
    const parsed = try std.json.parseFromSlice(Wire, allocator, bytes, .{});
    defer parsed.deinit();
    const v = parsed.value;
    if (v.port == 0 or v.token.len == 0 or v.token.len > 256 or v.pid == 0) return error.InvalidCredentials;
    if (std.mem.indexOfAny(u8, v.token, "\r\n\x00") != null) return error.InvalidCredentials;
    return .{ .port = v.port, .token = types.Text(256).init(v.token), .pid = v.pid };
}

const win = @import("windows.zig");
const c = win.c;
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
    pub const Status = enum { starting, ready, not_running, admin_required, failed };
    status: Status = .starting,
    credentials: Credentials = .{ .port = 0, .pid = 0, .token = .{} },
    revision: u64 = 0,
    attempt: u64 = 0,

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
    }
};

/// Discovery runs independently of the automation loop. A process handle detects
/// exit immediately; periodic command-line reads also detect PID/port/token changes.
pub const Watcher = struct {
    mutex: win.Mutex = .{},
    identity: Identity = .{},
    stopping: std.atomic.Value(bool) = .init(false),
    poke: c.HANDLE,
    thread: ?std.Thread = null,

    pub fn create() !*Watcher {
        const self = try std.heap.page_allocator.create(Watcher);
        errdefer std.heap.page_allocator.destroy(self);
        const poke = c.CreateEventW(null, 0, 0, null) orelse return error.AuthWatchEvent;
        errdefer _ = c.CloseHandle(poke);
        self.* = .{ .poke = poke };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    pub fn destroy(self: *Watcher) void {
        self.stopping.store(true, .release);
        self.refresh();
        if (self.thread) |thread| thread.join();
        _ = c.CloseHandle(self.poke);
        @memset(std.mem.asBytes(&self.identity), 0);
        std.heap.page_allocator.destroy(self);
    }
    pub fn refresh(self: *Watcher) void {
        _ = c.SetEvent(self.poke);
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
    fn run(self: *Watcher) void {
        var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{ .environ = .{ .block = .global } });
        defer threaded.deinit();
        while (!self.stopping.load(.acquire)) {
            var credentials = discover(std.heap.page_allocator, threaded.io()) catch |err| {
                self.update(switch (err) {
                    error.ClientNotRunning => .not_running,
                    error.AdminRequired => .admin_required,
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
