const std = @import("std");
const c = @import("windows.zig").c;
const a = std.heap.page_allocator;

/// Async WinHTTP with one operation in flight. Cancellation wakes the receiver;
/// HANDLE_CLOSING is drained before releasing callback state or I/O buffers.
/// Closing a synchronous WinHTTP receive from another thread is not supported.
pub const Socket = struct {
    session: c.HINTERNET = null,
    connection: c.HINTERNET = null,
    handle: c.HINTERNET = null,
    completed: c.HANDLE,
    closed: c.HANDLE,
    cancelled: c.HANDLE,
    failure: std.atomic.Value(u32) = .init(0),
    count: u32 = 0,
    kind: c.WINHTTP_WEB_SOCKET_BUFFER_TYPE = 0,
    buffer: [16384]u8 = undefined,

    pub fn create(port: u16, authorization: [*]const u16) !*Socket {
        const completed = c.CreateEventW(null, 0, 0, null) orelse return error.SocketEvent;
        errdefer _ = c.CloseHandle(completed);
        const closed = c.CreateEventW(null, 0, 0, null) orelse return error.SocketEvent;
        errdefer _ = c.CloseHandle(closed);
        const cancelled = c.CreateEventW(null, 1, 0, null) orelse return error.SocketEvent;
        errdefer _ = c.CloseHandle(cancelled);
        const self = try a.create(Socket);
        errdefer a.destroy(self);
        self.* = .{ .completed = completed, .closed = closed, .cancelled = cancelled };
        self.session = c.WinHttpOpen(std.unicode.utf8ToUtf16LeStringLiteral("catengar/0.1"), c.WINHTTP_ACCESS_TYPE_NO_PROXY, null, null, c.WINHTTP_FLAG_ASYNC) orelse return error.HttpOpen;
        errdefer _ = c.WinHttpCloseHandle(self.session);
        // WinHTTP otherwise shares pooled TCP connections across sessions.
        // LCU may route a connection as REST at its first request and reject
        // a later WebSocket upgrade on that socket. Each WS gets its own pool.
        var private_pool: c.BOOL = 1;
        const isolated = c.WinHttpSetOption(self.session, c.WINHTTP_OPTION_DISABLE_GLOBAL_POOLING, &private_pool, @sizeOf(c.BOOL)) != 0;
        _ = c.WinHttpSetTimeouts(self.session, 1500, 1500, 1500, 1500);
        self.connection = c.WinHttpConnect(self.session, std.unicode.utf8ToUtf16LeStringLiteral("127.0.0.1"), port, 0) orelse return error.HttpConnect;
        errdefer _ = c.WinHttpCloseHandle(self.connection);
        const request = c.WinHttpOpenRequest(self.connection, std.unicode.utf8ToUtf16LeStringLiteral("GET"), std.unicode.utf8ToUtf16LeStringLiteral("/"), null, null, null, c.WINHTTP_FLAG_SECURE) orelse return error.WebSocketRequest;
        var registered = false;
        defer if (registered) self.close(request) else {
            _ = c.WinHttpCloseHandle(request);
        };
        // Older WinHTTP versions lack the session pooling option.
        if (!isolated) {
            var disable: u32 = c.WINHTTP_DISABLE_KEEP_ALIVE;
            if (c.WinHttpSetOption(request, c.WINHTTP_OPTION_DISABLE_FEATURE, &disable, @sizeOf(u32)) == 0) return error.SocketPooling;
        }
        var context: usize = @intFromPtr(self);
        if (c.WinHttpSetOption(request, c.WINHTTP_OPTION_CONTEXT_VALUE, &context, @sizeOf(usize)) == 0) return error.SocketContext;
        const previous = c.WinHttpSetStatusCallback(request, callback, c.WINHTTP_CALLBACK_FLAG_ALL_COMPLETIONS | c.WINHTTP_CALLBACK_FLAG_HANDLES, 0);
        if (@intFromPtr(previous) == std.math.maxInt(usize)) return error.SocketCallback;
        registered = true;
        var security: u32 = c.SECURITY_FLAG_IGNORE_UNKNOWN_CA | c.SECURITY_FLAG_IGNORE_CERT_CN_INVALID | c.SECURITY_FLAG_IGNORE_CERT_DATE_INVALID | c.SECURITY_FLAG_IGNORE_CERT_WRONG_USAGE;
        if (c.WinHttpSetOption(request, c.WINHTTP_OPTION_SECURITY_FLAGS, &security, @sizeOf(u32)) == 0) return error.TlsOptions;
        var redirects: u32 = c.WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
        if (c.WinHttpSetOption(request, c.WINHTTP_OPTION_REDIRECT_POLICY, &redirects, @sizeOf(u32)) == 0) return error.RedirectOptions;
        if (c.WinHttpSetOption(request, c.WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, null, 0) == 0) return error.WebSocketUpgrade;
        if (c.WinHttpSendRequest(request, authorization, 0xffffffff, null, 0, 0, context) == 0) return error.HttpSend;
        try self.wait(5000);
        if (c.WinHttpReceiveResponse(request, null) == 0) return error.HttpReceive;
        try self.wait(5000);
        var status: u32 = 0;
        var size: u32 = @sizeOf(u32);
        if (c.WinHttpQueryHeaders(request, c.WINHTTP_QUERY_STATUS_CODE | c.WINHTTP_QUERY_FLAG_NUMBER, null, &status, &size, null) == 0) return error.HttpHeaders;
        if (status == 401 or status == 403) return error.AuthenticationExpired;
        if (status != 101) return error.WebSocketUpgrade;
        self.handle = c.WinHttpWebSocketCompleteUpgrade(request, context) orelse return error.WebSocketUpgrade;
        return self;
    }
    fn callback(_: c.HINTERNET, context: usize, status: u32, info: ?*anyopaque, _: u32) callconv(.winapi) void {
        if (context == 0) return;
        const self: *Socket = @ptrFromInt(context);
        switch (status) {
            c.WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING => {
                _ = c.SetEvent(self.closed);
                return;
            },
            c.WINHTTP_CALLBACK_STATUS_REQUEST_ERROR => {
                const result: *const c.WINHTTP_ASYNC_RESULT = @ptrCast(@alignCast(info.?));
                self.failure.store(result.dwError, .release);
            },
            c.WINHTTP_CALLBACK_STATUS_READ_COMPLETE => {
                const result: *const c.WINHTTP_WEB_SOCKET_STATUS = @ptrCast(@alignCast(info.?));
                self.count = result.dwBytesTransferred;
                self.kind = result.eBufferType;
            },
            c.WINHTTP_CALLBACK_STATUS_WRITE_COMPLETE, c.WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE, c.WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE => {},
            else => return,
        }
        _ = c.SetEvent(self.completed);
    }
    fn wait(self: *Socket, timeout: u32) !void {
        const handles = [_]c.HANDLE{ self.cancelled, self.completed };
        switch (c.WaitForMultipleObjects(handles.len, &handles, 0, timeout)) {
            c.WAIT_OBJECT_0 => return error.SocketCancelled,
            c.WAIT_OBJECT_0 + 1 => if (self.failure.load(.acquire) != 0) {
                return error.SocketOperation;
            },
            c.WAIT_TIMEOUT => return error.SocketTimeout,
            else => return error.SocketWait,
        }
    }
    fn close(self: *Socket, handle: c.HINTERNET) void {
        _ = c.WinHttpCloseHandle(handle);
        _ = c.WaitForSingleObject(self.closed, c.INFINITE);
    }
    pub fn cancel(self: *Socket) void {
        _ = c.SetEvent(self.cancelled);
    }
    pub fn destroy(self: *Socket) void {
        // Caller joins its receive thread first. Async I/O may still be pending;
        // our receive buffer remains owned here until the final close callback.
        self.close(self.handle);
        _ = c.WinHttpCloseHandle(self.connection);
        _ = c.WinHttpCloseHandle(self.session);
        _ = c.CloseHandle(self.completed);
        _ = c.CloseHandle(self.closed);
        _ = c.CloseHandle(self.cancelled);
        a.destroy(self);
    }
    pub fn send(self: *Socket, bytes: []u8) !void {
        // Own the buffer until destruction, including on timeout/cancellation.
        if (bytes.len > self.buffer.len) return error.WebSocketMessageSize;
        @memcpy(self.buffer[0..bytes.len], bytes);
        if (c.WinHttpWebSocketSend(self.handle, c.WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE, &self.buffer, @intCast(bytes.len)) != 0) return error.WebSocketSubscribe;
        try self.wait(3000);
    }
    pub fn receive(self: *Socket) ![]const u8 {
        if (c.WinHttpWebSocketReceive(self.handle, &self.buffer, self.buffer.len, null, null) != 0) return error.WebSocketReceive;
        try self.wait(c.INFINITE);
        return self.buffer[0..self.count];
    }
};
