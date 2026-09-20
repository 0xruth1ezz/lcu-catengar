const std = @import("std");
const win = @import("windows.zig");
const c = win.c;
const wire = @import("auth_protocol.zig");
const a = std.heap.page_allocator;
const wide = std.unicode.utf8ToUtf16LeStringLiteral;

pub fn siblingPath(name: []const u8) ![]const u8 {
    var buffer: [32768]u16 = undefined;
    const len = c.GetModuleFileNameW(null, &buffer, buffer.len);
    if (len == 0 or len >= buffer.len) return error.HelperPath;
    const path = try std.unicode.utf16LeToUtf8Alloc(a, buffer[0..len]);
    defer a.free(path);
    return std.fs.path.join(a, &.{ std.fs.path.dirname(path) orelse return error.HelperPath, name });
}

pub fn validNonce(nonce: []const u8) bool {
    if (nonce.len != 32) return false;
    for (nonce) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

fn pipeName(nonce: []const u8) ![:0]u16 {
    if (!validNonce(nonce)) return error.InvalidHelperArguments;
    const path = try std.fmt.allocPrint(a, "\\\\.\\pipe\\catengar.auth.{s}", .{nonce});
    defer a.free(path);
    return std.unicode.utf8ToUtf16LeAllocZ(a, path);
}

// Cancel and drain before an OVERLAPPED's stack storage is released.
fn finish(pipe: c.HANDLE, operation: *c.OVERLAPPED, wake: c.HANDLE, peer: c.HANDLE, timeout: u32) !u32 {
    const handles = [_]c.HANDLE{ operation.hEvent, wake, peer };
    const outcome = c.WaitForMultipleObjects(if (wake == peer) 2 else handles.len, &handles, 0, timeout);
    if (outcome != c.WAIT_OBJECT_0) {
        _ = c.CancelIoEx(pipe, operation);
        var discarded: c.DWORD = 0;
        _ = c.GetOverlappedResult(pipe, operation, &discarded, 1);
        return switch (outcome) {
            c.WAIT_OBJECT_0 + 1 => error.Interrupted,
            c.WAIT_OBJECT_0 + 2 => error.HelperExited,
            c.WAIT_TIMEOUT => error.HelperTimeout,
            else => error.HelperPipe,
        };
    }
    var transferred: c.DWORD = 0;
    if (c.GetOverlappedResult(pipe, operation, &transferred, 0) == 0) return error.HelperPipe;
    return transferred;
}

pub const Server = struct {
    pipe: c.HANDLE,
    event: c.HANDLE,
    nonce: [32]u8,

    pub fn create() !Server {
        var random: [16]u8 = undefined;
        if (c.BCryptGenRandom(null, &random, random.len, c.BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0) return error.HelperRandom;
        const nonce = std.fmt.bytesToHex(random, .lower);
        const name = try pipeName(&nonce);
        defer a.free(name);
        var token: c.HANDLE = null;
        if (c.OpenProcessToken(c.GetCurrentProcess(), c.TOKEN_QUERY, &token) == 0) return error.HelperSecurity;
        defer _ = c.CloseHandle(token);
        var user: [512]u8 align(@alignOf(c.TOKEN_USER)) = undefined;
        var needed: c.DWORD = 0;
        if (c.GetTokenInformation(token, c.TokenUser, &user, user.len, &needed) == 0) return error.HelperSecurity;
        const info: *const c.TOKEN_USER = @ptrCast(&user);
        var sid: c.LPWSTR = null;
        if (c.ConvertSidToStringSidW(info.User.Sid, &sid) == 0) return error.HelperSecurity;
        defer _ = c.LocalFree(sid);
        const sid_text = try std.unicode.utf16LeToUtf8Alloc(a, std.mem.span(sid));
        defer a.free(sid_text);
        // Explicit DACL: no Everyone/anonymous defaults. An administrator using
        // over-the-shoulder UAC is permitted; the actual child PID is still checked.
        const sddl = try std.fmt.allocPrint(a, "D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GA;;;{s})", .{sid_text});
        defer a.free(sddl);
        const sddl_wide = try std.unicode.utf8ToUtf16LeAllocZ(a, sddl);
        defer a.free(sddl_wide);
        var descriptor: c.PSECURITY_DESCRIPTOR = null;
        if (c.ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl_wide, 1, &descriptor, null) == 0) return error.HelperSecurity;
        defer _ = c.LocalFree(descriptor);
        var attrs: c.SECURITY_ATTRIBUTES = .{ .nLength = @sizeOf(c.SECURITY_ATTRIBUTES), .lpSecurityDescriptor = descriptor, .bInheritHandle = 0 };
        const pipe = c.CreateNamedPipeW(name, c.PIPE_ACCESS_INBOUND | c.FILE_FLAG_OVERLAPPED | c.FILE_FLAG_FIRST_PIPE_INSTANCE, c.PIPE_TYPE_MESSAGE | c.PIPE_READMODE_MESSAGE | c.PIPE_REJECT_REMOTE_CLIENTS, 1, wire.size, wire.size, 0, &attrs);
        if (pipe == c.INVALID_HANDLE_VALUE) return error.HelperPipe;
        errdefer _ = c.CloseHandle(pipe);
        const event = c.CreateEventW(null, 1, 0, null) orelse return error.HelperPipe;
        return .{ .pipe = pipe, .event = event, .nonce = nonce };
    }

    pub fn accept(self: *Server, process: c.HANDLE, wake: c.HANDLE) !void {
        _ = c.ResetEvent(self.event);
        var operation = std.mem.zeroes(c.OVERLAPPED);
        operation.hEvent = self.event;
        if (c.ConnectNamedPipe(self.pipe, &operation) == 0) {
            switch (c.GetLastError()) {
                c.ERROR_PIPE_CONNECTED => {},
                c.ERROR_IO_PENDING => _ = try finish(self.pipe, &operation, wake, process, 15000),
                else => return error.HelperPipe,
            }
        }
        try self.verifyClient(process);
    }

    pub fn verifyClient(self: *Server, process: c.HANDLE) !void {
        var pid: c.ULONG = 0;
        if (c.GetNamedPipeClientProcessId(self.pipe, &pid) == 0 or pid != c.GetProcessId(process)) return error.HelperIdentity;
    }

    pub fn read(self: *Server, process: c.HANDLE, wake: c.HANDLE) !wire.Result {
        var bytes: [wire.size]u8 = @splat(0);
        defer @memset(&bytes, 0);
        _ = c.ResetEvent(self.event);
        var operation = std.mem.zeroes(c.OVERLAPPED);
        operation.hEvent = self.event;
        if (c.ReadFile(self.pipe, &bytes, bytes.len, null, &operation) == 0 and c.GetLastError() != c.ERROR_IO_PENDING) return error.HelperPipe;
        const count = try finish(self.pipe, &operation, wake, process, 20000);
        return wire.decode(bytes[0..count]);
    }

    pub fn deinit(self: *Server) void {
        _ = c.CloseHandle(self.pipe);
        _ = c.CloseHandle(self.event);
    }
};

// ShellExecuteEx may wait for the user's UAC decision. A detached, reference-
// counted launcher keeps that wait off both the UI and its shutdown path.
const Launch = struct {
    refs: std.atomic.Value(u32) = .init(2),
    mutex: win.Mutex = .{},
    done: c.HANDLE,
    path: [:0]u16,
    args: [:0]u16,
    command: [:0]u16,
    elevated: bool,
    process: c.HANDLE = null,
    cancelled: bool = false,

    fn release(self: *Launch) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.process != null) _ = c.CloseHandle(self.process);
        _ = c.CloseHandle(self.done);
        a.free(self.path);
        a.free(self.args);
        a.free(self.command);
        a.destroy(self);
    }

    fn run(self: *Launch) void {
        defer self.release();
        // An already elevated parent can pass its real token directly to the
        // helper. The absence/presence of a UAC window is never a success signal.
        if (!self.elevated) {
            var startup = std.mem.zeroes(c.STARTUPINFOW);
            startup.cb = @sizeOf(c.STARTUPINFOW);
            startup.dwFlags = c.STARTF_USESHOWWINDOW;
            startup.wShowWindow = c.SW_HIDE;
            var process = std.mem.zeroes(c.PROCESS_INFORMATION);
            const ok = c.CreateProcessW(self.path, self.command, null, null, 0, c.CREATE_NO_WINDOW, null, null, &startup, &process);
            self.mutex.lock();
            if (ok != 0) {
                _ = c.CloseHandle(process.hThread);
                self.process = process.hProcess;
            }
            self.mutex.unlock();
            _ = c.SetEvent(self.done);
            return;
        }
        const com = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED | c.COINIT_DISABLE_OLE1DDE);
        defer if (com >= 0) c.CoUninitialize();
        var request = std.mem.zeroes(c.SHELLEXECUTEINFOW);
        request.cbSize = @sizeOf(c.SHELLEXECUTEINFOW);
        request.hwnd = win.authorizationOwner();
        request.fMask = c.SEE_MASK_NOCLOSEPROCESS | c.SEE_MASK_NOASYNC | c.SEE_MASK_FLAG_NO_UI;
        request.lpVerb = if (self.elevated) wide("runas") else wide("open");
        request.lpFile = self.path;
        request.lpParameters = self.args;
        request.nShow = c.SW_HIDE;
        const ok = c.ShellExecuteExW(&request);
        const cancelled = ok == 0 and c.GetLastError() == c.ERROR_CANCELLED;
        self.mutex.lock();
        self.process = if (ok != 0) request.hProcess else null;
        self.cancelled = cancelled;
        self.mutex.unlock();
        _ = c.SetEvent(self.done);
    }

    fn start(path: []const u8, args: []const u8, elevated: bool, wake: c.HANDLE) !c.HANDLE {
        const self = try create(path, args, elevated);
        return self.wait(wake);
    }

    fn create(path: []const u8, args: []const u8, elevated: bool) !*Launch {
        const self = try a.create(Launch);
        errdefer a.destroy(self);
        const path_wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
        errdefer a.free(path_wide);
        if (c.GetFileAttributesW(path_wide) == c.INVALID_FILE_ATTRIBUTES) return error.HelperMissing;
        const args_wide = try std.unicode.utf8ToUtf16LeAllocZ(a, args);
        errdefer a.free(args_wide);
        const command_text = try std.fmt.allocPrint(a, "\"{s}\" {s}", .{ path, args });
        defer a.free(command_text);
        const command = try std.unicode.utf8ToUtf16LeAllocZ(a, command_text);
        errdefer a.free(command);
        const done = c.CreateEventW(null, 1, 0, null) orelse return error.HelperLaunch;
        errdefer _ = c.CloseHandle(done);
        self.* = .{ .path = path_wide, .args = args_wide, .command = command, .done = done, .elevated = elevated };
        const thread = try std.Thread.spawn(.{}, run, .{self});
        thread.detach();
        return self;
    }

    fn wait(self: *Launch, wake: c.HANDLE) !c.HANDLE {
        defer self.release();
        const handles = [_]c.HANDLE{ self.done, wake };
        if (c.WaitForMultipleObjects(handles.len, &handles, 0, c.INFINITE) != c.WAIT_OBJECT_0) return error.Interrupted;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.process == null) return if (self.cancelled) error.HelperCancelled else error.HelperLaunch;
        const process = self.process;
        self.process = null;
        return process;
    }
};

pub const Client = struct {
    server: Server,
    process: c.HANDLE,

    pub fn start(wake: c.HANDLE) !Client {
        const path = try siblingPath("catengar-auth.exe");
        defer a.free(path);
        var client = try spawn(path, !win.isAdmin(), wake);
        errdefer client.deinit();
        if (!try win.processIsElevated(client.process)) return error.HelperNotElevated;
        return client;
    }

    // Test executables use a separate, non-elevated fixture. The production
    // caller above launches only the fixed sibling helper, inheriting an
    // elevated token when available and using runas otherwise.
    pub fn spawn(path: []const u8, elevated: bool, wake: c.HANDLE) !Client {
        var server = try Server.create();
        errdefer server.deinit();
        const args = try std.fmt.allocPrint(a, "--pipe {s} --parent {d}", .{ server.nonce, c.GetCurrentProcessId() });
        defer a.free(args);
        const process = try Launch.start(path, args, elevated, wake);
        errdefer _ = c.CloseHandle(process);
        try server.accept(process, wake);
        return .{ .server = server, .process = process };
    }

    pub fn read(self: *Client, wake: c.HANDLE) !wire.Result {
        return self.server.read(self.process, wake);
    }

    pub fn deinit(self: *Client) void {
        // Closing the only pipe notifies the helper. It has no persistent service
        // or scheduled task and also watches the parent's process handle.
        self.server.deinit();
        _ = c.CloseHandle(self.process);
    }
};

pub const Sender = struct {
    pipe: c.HANDLE,
    parent: c.HANDLE,
    event: c.HANDLE,

    pub fn connect(nonce: []const u8, parent_id: u32, expected_parent: ?[]const u8) !Sender {
        if (parent_id == 0) return error.InvalidHelperArguments;
        const parent = c.OpenProcess(c.SYNCHRONIZE | c.PROCESS_QUERY_LIMITED_INFORMATION, 0, parent_id) orelse return error.HelperParent;
        errdefer _ = c.CloseHandle(parent);
        if (c.WaitForSingleObject(parent, 0) != c.WAIT_TIMEOUT) return error.HelperParent;
        if (expected_parent) |filename| {
            const expected = try siblingPath(filename);
            defer a.free(expected);
            const expected_wide = try std.unicode.utf8ToUtf16LeAllocZ(a, expected);
            defer a.free(expected_wide);
            var actual: [32768]u16 = undefined;
            var len: c.DWORD = actual.len;
            if (c.QueryFullProcessImageNameW(parent, 0, &actual, &len) == 0 or c.CompareStringOrdinal(expected_wide, @intCast(expected_wide.len), &actual, @intCast(len), 1) != c.CSTR_EQUAL) return error.HelperParent;
        }
        const name = try pipeName(nonce);
        defer a.free(name);
        // Identification-only QoS forbids a malicious pipe server from
        // impersonating this elevated client.
        const pipe = c.CreateFileW(name, c.GENERIC_WRITE | c.FILE_READ_ATTRIBUTES, 0, null, c.OPEN_EXISTING, c.FILE_FLAG_OVERLAPPED | c.SECURITY_SQOS_PRESENT | c.SECURITY_IDENTIFICATION, null);
        if (pipe == c.INVALID_HANDLE_VALUE) return error.HelperPipe;
        errdefer _ = c.CloseHandle(pipe);
        var owner: c.ULONG = 0;
        if (c.GetNamedPipeServerProcessId(pipe, &owner) == 0 or owner != parent_id) return error.HelperIdentity;
        const event = c.CreateEventW(null, 1, 0, null) orelse return error.HelperPipe;
        return .{ .pipe = pipe, .parent = parent, .event = event };
    }

    pub fn write(self: *Sender, result: wire.Result) !void {
        var bytes = wire.encode(result);
        defer @memset(&bytes, 0);
        _ = c.ResetEvent(self.event);
        var operation = std.mem.zeroes(c.OVERLAPPED);
        operation.hEvent = self.event;
        if (c.WriteFile(self.pipe, &bytes, bytes.len, null, &operation) == 0 and c.GetLastError() != c.ERROR_IO_PENDING) return error.HelperPipe;
        if (try finish(self.pipe, &operation, self.parent, self.parent, 2000) != bytes.len) return error.HelperPipe;
    }

    pub fn deinit(self: *Sender) void {
        _ = c.CloseHandle(self.pipe);
        _ = c.CloseHandle(self.parent);
        _ = c.CloseHandle(self.event);
    }
};

pub fn arguments(args: []const []const u8) !struct { nonce: []const u8, parent: u32 } {
    if (args.len != 5 or !std.mem.eql(u8, args[1], "--pipe") or !validNonce(args[2]) or !std.mem.eql(u8, args[3], "--parent")) return error.InvalidHelperArguments;
    const parent = std.fmt.parseInt(u32, args[4], 10) catch return error.InvalidHelperArguments;
    if (parent == 0) return error.InvalidHelperArguments;
    return .{ .nonce = args[2], .parent = parent };
}
