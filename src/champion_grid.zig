const std = @import("std");

pub const tile_height: f32 = 96;
pub const gap: f32 = 10;
pub const stride: f32 = tile_height + gap;

pub fn columns(canvas_width: f32) usize {
    // Window padding (48), shared panel padding (36), two arrow gaps (48),
    // and the 24 px arrow are shared by the two equal columns.
    const library_width = @max(1, (canvas_width - 156) / 2);
    return @intFromFloat(std.math.clamp(@floor((library_width + gap) / (tile_height + gap)), 2, 10));
}

pub const Window = struct {
    start: usize,
    end: usize,
    top: f32,
    bottom: f32,
};

/// Keep the full scrollbar extent while mounting only nearby rows. The
/// entire canvas height is a conservative viewport bound, also on resize.
pub fn window(count: usize, cols: usize, offset: f32, height: f32) Window {
    if (count == 0) return .{ .start = 0, .end = 0, .top = 0, .bottom = 0 };
    const rows = std.math.divCeil(usize, count, cols) catch unreachable;
    const first = @min(rows - 1, @as(usize, @intFromFloat(@floor(@max(0, offset) / stride))));
    const start = first -| 1;
    const visible: usize = @intFromFloat(@ceil(@max(stride, height) / stride));
    const end = @min(rows, first + visible + 1);
    return .{
        .start = start * cols,
        .end = @min(count, end * cols),
        .top = @as(f32, @floatFromInt(start)) * stride,
        .bottom = @as(f32, @floatFromInt(rows - end)) * stride,
    };
}
