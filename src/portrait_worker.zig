const std = @import("std");
const t = @import("types.zig");
const win = @import("windows.zig");
const portraits = @import("portraits.zig");
const a = std.heap.page_allocator;
const capacity = 8;

// The pinned Windows C codec is context-free: it initializes COM on the
// calling thread and owns/releases every WIC object locally. Do not use the
// loop-only PlatformServices wrapper or touch the runtime's registry here.
extern fn native_sdk_windows_decode_image(bytes: [*]const u8, bytes_len: usize, pixels: [*]u8, pixels_len: usize, max_pixels: usize, width: *usize, height: *usize) c_int;

pub const Job = struct { generation: u64, index: usize, path: t.Text(768) };
pub const Result = struct {
    generation: u64,
    index: usize,
    pixels: ?[]u8 = null,
    pub fn deinit(self: Result) void {
        if (self.pixels) |pixels| a.free(pixels);
    }
};

pub const Worker = struct {
    mutex: win.Mutex = .{},
    jobs: [capacity]Job = undefined,
    job_count: usize = 0,
    results: [capacity]Result = undefined,
    result_count: usize = 0,
    stopping: std.atomic.Value(bool) = .init(false),
    wake: win.c.HANDLE,
    thread: ?std.Thread = null,
    notify: *const fn () bool,

    pub fn create(notify: *const fn () bool) !*Worker {
        const self = try a.create(Worker);
        errdefer a.destroy(self);
        const wake = win.c.CreateEventW(null, 0, 0, null) orelse return error.PortraitEvent;
        errdefer _ = win.c.CloseHandle(wake);
        self.* = .{ .wake = wake, .notify = notify };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    pub fn destroy(self: *Worker) void {
        self.stopping.store(true, .release);
        _ = win.c.SetEvent(self.wake);
        if (self.thread) |thread| thread.join();
        for (self.results[0..self.result_count]) |result| result.deinit();
        _ = win.c.CloseHandle(self.wake);
        a.destroy(self);
    }
    pub fn submit(self: *Worker, job: Job) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.job_count == capacity) return false;
        self.jobs[self.job_count] = job;
        self.job_count += 1;
        _ = win.c.SetEvent(self.wake);
        return true;
    }
    pub fn take(self: *Worker) ?Result {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.result_count == 0) return null;
        self.result_count -= 1;
        const result = self.results[self.result_count];
        _ = win.c.SetEvent(self.wake);
        return result;
    }
    pub fn cancelQueued(self: *Worker) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.job_count = 0;
        // An in-flight result is tagged; the UI discards old generations.
        for (self.results[0..self.result_count]) |result| result.deinit();
        self.result_count = 0;
        _ = win.c.SetEvent(self.wake);
    }
    fn run(self: *Worker) void {
        var threaded: std.Io.Threaded = .init(a, .{});
        defer threaded.deinit();
        while (!self.stopping.load(.acquire)) {
            self.mutex.lock();
            if (self.job_count == 0 or self.result_count == capacity) {
                self.mutex.unlock();
                _ = win.c.WaitForSingleObject(self.wake, win.c.INFINITE);
                continue;
            }
            const job = self.jobs[0];
            self.job_count -= 1;
            std.mem.copyForwards(Job, self.jobs[0..self.job_count], self.jobs[1..][0..self.job_count]);
            self.mutex.unlock();
            const result: Result = .{ .generation = job.generation, .index = job.index, .pixels = decode(threaded.io(), job.path.text()) catch null };
            self.mutex.lock();
            self.results[self.result_count] = result;
            self.result_count += 1;
            const ready = self.job_count == 0 or self.result_count >= 4;
            self.mutex.unlock();
            if (ready and !self.notify()) return;
        }
    }
};

fn decode(io: std.Io, path: []const u8) ![]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(2 * 1024 * 1024));
    defer a.free(bytes);
    var scratch: [portraits.tile * portraits.tile * 4]u8 = undefined;
    var width: usize = 0;
    var height: usize = 0;
    if (native_sdk_windows_decode_image(bytes.ptr, bytes.len, &scratch, scratch.len, portraits.tile * portraits.tile, &width, &height) != 1) return error.PortraitDecode;
    if (width == 0 or height == 0 or width > portraits.tile or height > portraits.tile) return error.PortraitDimensions;
    const result = try a.alloc(u8, scratch.len);
    for (0..portraits.tile) |y| {
        for (0..portraits.tile) |x| {
            const from = ((y * height / portraits.tile) * width + x * width / portraits.tile) * 4;
            const to = (y * portraits.tile + x) * 4;
            @memcpy(result[to..][0..4], scratch[from..][0..4]);
        }
    }
    return result;
}
