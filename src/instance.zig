const std = @import("std");
const win = @import("windows.zig");
const c = win.c;

/// A kernel file lock is shared by normal and elevated launches of this user.
/// It is released by Windows even after a crash; the file's existence is irrelevant.
pub const Instance = struct {
    lock: c.HANDLE,
    activation: c.HANDLE,
    stopping: std.atomic.Value(bool) = .init(false),
    pending: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn acquire(a: std.mem.Allocator, io: std.Io, root: []const u8) !?Instance {
        try std.Io.Dir.cwd().createDirPath(io, root);
        const path = try std.fs.path.join(a, &.{ root, "catengar.lock" });
        defer a.free(path);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
        defer a.free(wide);
        const name = try std.fmt.allocPrint(a, "Local\\catengar.activate.{x}", .{std.hash.Wyhash.hash(0, root)});
        defer a.free(name);
        const event_name = try std.unicode.utf8ToUtf16LeAllocZ(a, name);
        defer a.free(event_name);
        // A medium-integrity launcher can signal an elevated owner's event.
        var descriptor: c.PSECURITY_DESCRIPTOR = null;
        if (c.ConvertStringSecurityDescriptorToSecurityDescriptorW(std.unicode.utf8ToUtf16LeStringLiteral("D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;GA;;;IU)S:(ML;;NW;;;ME)"), 1, &descriptor, null) == 0) return error.InstanceSecurity;
        defer _ = c.LocalFree(descriptor);
        var attrs: c.SECURITY_ATTRIBUTES = .{ .nLength = @sizeOf(c.SECURITY_ATTRIBUTES), .lpSecurityDescriptor = descriptor, .bInheritHandle = 0 };
        const event = c.CreateEventW(&attrs, 0, 0, event_name.ptr) orelse return error.InstanceEvent;
        errdefer _ = c.CloseHandle(event);
        const handle = c.CreateFileW(wide.ptr, c.GENERIC_READ | c.GENERIC_WRITE, 0, null, c.OPEN_ALWAYS, c.FILE_ATTRIBUTE_NORMAL, null);
        if (handle != c.INVALID_HANDLE_VALUE) return .{ .lock = handle, .activation = event };
        if (c.GetLastError() != c.ERROR_SHARING_VIOLATION) return error.InstanceLock;
        _ = c.SetEvent(event);
        _ = c.CloseHandle(event);
        return null;
    }

    pub fn watch(self: *Instance, notify: *const fn () bool) !void {
        self.thread = try std.Thread.spawn(.{}, listen, .{ self, notify });
    }
    fn listen(self: *Instance, notify: *const fn () bool) void {
        while (!self.stopping.load(.acquire)) {
            if (c.WaitForSingleObject(self.activation, 200) == c.WAIT_OBJECT_0 and !self.stopping.load(.acquire)) {
                self.pending.store(true, .release);
                if (!notify()) break;
            }
        }
    }
    pub fn takeActivation(self: *Instance) bool {
        return self.pending.swap(false, .acq_rel);
    }
    pub fn deinit(self: *Instance) void {
        self.stopping.store(true, .release);
        _ = c.SetEvent(self.activation);
        if (self.thread) |thread| thread.join();
        _ = c.CloseHandle(self.activation);
        _ = c.CloseHandle(self.lock);
    }
};
