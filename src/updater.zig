const std = @import("std");
const t = @import("types.zig");
const win = @import("windows.zig");
const a = std.heap.page_allocator;

pub const Status = enum { idle, checking, current, available, downloading, ready, arming, armed, failed };
pub const Action = enum { Check, Prepare, Install };
pub const Result = struct {
    status: Status = .failed,
    version: t.Text(32) = .{},
    sha256: t.Text(64) = .{},
    stage: t.Text(2048) = .{},
    ticket: t.Text(2048) = .{},
    message: t.Text(384) = .{},
};
pub const State = struct {
    status: Status = .idle,
    version: t.Text(32) = .{},
    sha256: t.Text(64) = .{},
    stage: t.Text(2048) = .{},
    message: t.Text(384) = .{},
    notice: t.Text(384) = .{},
    notified_version: t.Text(32) = .{},

    pub fn busy(self: *const State) bool {
        return self.status == .checking or self.status == .downloading or self.status == .arming;
    }
    pub fn available(self: *const State) bool {
        return self.status == .available or self.status == .ready;
    }
    pub fn checkDisabled(self: *const State) bool {
        return self.busy() or self.status == .ready;
    }
    pub fn failed(self: *const State) bool {
        return self.status == .failed;
    }
    pub fn description(self: *const State) []const u8 {
        return switch (self.status) {
            .idle => "启动后自动检查 GitHub 正式版",
            .checking => "正在检查新版本…",
            .current => "已是最新正式版",
            .available => "新版本已发布，更新后自动重启",
            .downloading => "正在下载并校验更新包，请稍候…",
            .ready => "更新包已就绪，可以安装并重启",
            .arming, .armed => "正在准备重启…",
            .failed => self.message.text(),
        };
    }
};
pub const Job = struct {
    action: Action,
    version: t.Text(32) = .{},
    sha256: t.Text(64) = .{},
    stage: t.Text(2048) = .{},
};

pub fn canInstall(snapshot: *const t.Snapshot) bool {
    if (!snapshot.connected) return true;
    const phase = snapshot.phase.text();
    for ([_][]const u8{ "None", "Lobby", "EndOfGame", "TerminatedInError" }) |idle| {
        if (std.mem.eql(u8, phase, idle)) return true;
    }
    return false;
}

pub const Worker = struct {
    root: []const u8,
    current: []const u8,
    mutex: win.Mutex = .{},
    job: ?Job = null,
    result: ?Result = null,
    stopping: std.atomic.Value(bool) = .init(false),
    wake: win.c.HANDLE,
    thread: ?std.Thread = null,
    notify: *const fn () bool,

    pub fn create(root: []const u8, current: []const u8, notify: *const fn () bool) !*Worker {
        const self = try a.create(Worker);
        errdefer a.destroy(self);
        const owned = try a.dupe(u8, root);
        errdefer a.free(owned);
        const wake = win.c.CreateEventW(null, 0, 0, null) orelse return error.UpdateEvent;
        errdefer _ = win.c.CloseHandle(wake);
        self.* = .{ .root = owned, .current = current, .wake = wake, .notify = notify };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    pub fn destroy(self: *Worker) void {
        self.stopping.store(true, .release);
        _ = win.c.SetEvent(self.wake);
        if (self.thread) |thread| thread.join();
        _ = win.c.CloseHandle(self.wake);
        a.free(self.root);
        a.destroy(self);
    }
    pub fn submit(self: *Worker, job: Job) void {
        self.mutex.lock();
        self.job = job;
        self.mutex.unlock();
        _ = win.c.SetEvent(self.wake);
    }
    pub fn take(self: *Worker) ?Result {
        self.mutex.lock();
        defer self.mutex.unlock();
        const value = self.result;
        self.result = null;
        return value;
    }
    fn run(self: *Worker) void {
        // PowerShell/.NET require the Windows environment (SystemRoot, TEMP,
        // user profile). Threaded defaults to an empty child environment.
        var threaded: std.Io.Threaded = .init(a, .{ .environ = .{ .block = .global } });
        defer threaded.deinit();
        while (!self.stopping.load(.acquire)) {
            self.mutex.lock();
            const job = self.job;
            self.job = null;
            self.mutex.unlock();
            if (job) |next| {
                const result = self.perform(threaded.io(), next) catch |err| blk: {
                    std.log.warn("Update worker failed: {s}", .{@errorName(err)});
                    break :blk Result{ .message = t.Text(384).init("更新服务未能完成，请稍后重试。") };
                };
                if (self.stopping.load(.acquire)) return;
                self.mutex.lock();
                self.result = result;
                self.mutex.unlock();
                if (!self.notify()) return;
            } else _ = win.c.WaitForSingleObject(self.wake, win.c.INFINITE);
        }
    }

    fn perform(self: *Worker, io: std.Io, job: Job) !Result {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const temp = arena.allocator();
        const directory = try std.fs.path.join(temp, &.{ self.root, "updates" });
        try std.Io.Dir.cwd().createDirPath(io, directory);
        const script = "\xef\xbb\xbf" ++ @embedFile("updater.ps1");
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(script, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        const engine = try std.fs.path.join(temp, &.{ directory, try std.fmt.allocPrint(temp, "engine-{s}.ps1", .{hex[0..16]}) });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = engine, .data = script });
        const request = try std.fs.path.join(temp, &.{ directory, try std.fmt.allocPrint(temp, "request-{d}-{d}.json", .{ win.c.GetCurrentProcessId(), win.now() }) });
        if (request.len + 16 >= 2048) return error.PathTooLong;
        const executable = try @import("auth_broker.zig").siblingPath("catengar.exe");
        defer a.free(executable);
        const receipt = try std.fs.path.join(temp, &.{ directory, "last-result.json" });
        const payload = try std.json.Stringify.valueAlloc(temp, .{
            .current = self.current,
            .version = job.version.text(),
            .sha256 = job.sha256.text(),
            .stage = job.stage.text(),
            .executable = executable,
            .parent = win.c.GetCurrentProcessId(),
            .receipt = receipt,
        }, .{});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = request, .data = payload });
        const result_path = try std.fmt.allocPrint(temp, "{s}.result", .{request});
        var detached = false;
        defer if (!detached) {
            std.Io.Dir.cwd().deleteFile(io, request) catch {};
            std.Io.Dir.cwd().deleteFile(io, result_path) catch {};
        };
        var system: [32768]u16 = undefined;
        const length = win.c.GetSystemDirectoryW(&system, system.len);
        if (length == 0 or length >= system.len) return error.SystemDirectory;
        const system_path = try std.unicode.utf16LeToUtf8Alloc(temp, system[0..length]);
        const powershell = try std.fs.path.join(temp, &.{ system_path, "WindowsPowerShell", "v1.0", "powershell.exe" });
        var child = try std.process.spawn(io, .{
            .argv = &.{ powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", engine, "-Mode", @tagName(job.action), "-Request", request },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .create_no_window = true,
        });
        defer if (!detached) child.kill(io);
        const started = win.now();
        const timeout: u64 = if (job.action == .Prepare) 240000 else if (job.action == .Install) 10000 else 30000;
        while (win.c.WaitForSingleObject(child.id.?, 100) == win.c.WAIT_TIMEOUT) {
            if (self.stopping.load(.acquire)) return error.Cancelled;
            if (win.now() - started > timeout) return error.UpdateTimeout;
            if (job.action == .Install) {
                const ready = try std.fmt.allocPrint(temp, "{s}.ready", .{request});
                if (std.Io.Dir.cwd().access(io, ready, .{})) |_| {
                    // The helper waits for a separate UI-thread commit and the
                    // exact parent process to exit before replacing any file.
                    _ = win.c.CloseHandle(child.id.?);
                    _ = win.c.CloseHandle(child.thread_handle);
                    detached = true;
                    return .{ .status = .armed, .ticket = t.Text(2048).init(request) };
                } else |_| {}
            }
        }
        _ = try child.wait(io);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, result_path, temp, .limited(8192));
        return parseResult(temp, bytes);
    }
};

fn parseResult(allocator: std.mem.Allocator, bytes: []const u8) !Result {
    const Wire = struct { status: []const u8, version: []const u8 = "", sha256: []const u8 = "", stage: []const u8 = "", message: []const u8 = "" };
    const parsed = try std.json.parseFromSlice(Wire, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const wire = parsed.value;
    if (wire.stage.len >= 2048 or wire.version.len >= 32) return error.ResultTooLong;
    return .{
        .status = if (std.mem.eql(u8, wire.status, "available")) .available else if (std.mem.eql(u8, wire.status, "current")) .current else if (std.mem.eql(u8, wire.status, "ready")) .ready else .failed,
        .version = t.Text(32).init(wire.version),
        .sha256 = t.Text(64).init(wire.sha256),
        .stage = t.Text(2048).init(wire.stage),
        .message = t.Text(384).init(wire.message),
    };
}

pub fn commit(ticket: []const u8) !void {
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const path = try std.fmt.allocPrint(a, "{s}.commit", .{ticket});
    defer a.free(path);
    try std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = path, .data = "install" });
}

pub fn readNotice(io: std.Io, root: []const u8) t.Text(384) {
    const path = std.fs.path.join(a, &.{ root, "updates", "last-result.json" }) catch return .{};
    defer a.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(8192)) catch return .{};
    defer a.free(bytes);
    const parsed = parseResult(a, bytes) catch return .{};
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    return parsed.message;
}

test "installation waits through matchmaking, selection, gameplay and unknown connected phases" {
    var snapshot: t.Snapshot = .{ .connected = true };
    for ([_][]const u8{ "Matchmaking", "ReadyCheck", "ChampSelect", "GameStart", "InProgress", "Reconnect", "NewPhase", "" }) |phase| {
        snapshot.phase.set(phase);
        try std.testing.expect(!canInstall(&snapshot));
    }
    snapshot.phase.set("Lobby");
    try std.testing.expect(canInstall(&snapshot));
}

test "native worker launches Windows PowerShell and receives an offline rejection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "更新 space's [path]", .default_dir);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "更新 space's [path]", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const Callback = struct {
        fn notify() bool {
            return true;
        }
    };
    const worker = try Worker.create(root, "0.1.1", Callback.notify);
    defer worker.destroy();
    // An absent stage is rejected before game/process checks or any network
    // request. Receiving its structured Chinese error proves the actual helper
    // launched with a usable environment and preserved Unicode paths/encoding.
    worker.submit(.{ .action = .Install, .stage = t.Text(2048).init("missing-update-stage") });
    for (0..150) |_| {
        if (worker.take()) |result| {
            try std.testing.expectEqual(Status.failed, result.status);
            try std.testing.expectEqualStrings("更新服务暂不可用，请检查网络连接或稍后重试。", result.message.text());
            return;
        }
        win.c.Sleep(100);
    }
    return error.UpdateHelperTimeout;
}
