const std = @import("std");
const t = @import("types.zig");

pub const tile = 128;
pub const side = 640;
pub const per_atlas = 25;
pub const atlas_count = (t.max_champions + per_atlas - 1) / per_atlas;

pub fn imageId(index: usize) u64 {
    return 0x43410000 + index / per_atlas;
}
pub fn x(index: usize) usize {
    return (index % 5) * tile;
}
pub fn y(index: usize) usize {
    return (index % per_atlas / 5) * tile;
}

/// Eleven 640px atlases cover all 256 champions, leaving image slots for
/// the account avatar. Grid and priority rows share these textures.
pub const Store = struct {
    pixels: [atlas_count][]u8 = @splat(&.{}),
    ready: [t.max_champions]bool = @splat(false),

    pub fn deinit(self: *Store, a: std.mem.Allocator) void {
        for (self.pixels) |bytes| if (bytes.len != 0) a.free(bytes);
        self.* = .{};
    }

    pub fn put(self: *Store, a: std.mem.Allocator, index: usize, width: usize, height: usize, rgba: []const u8) ![]const u8 {
        if (index >= t.max_champions or width == 0 or height == 0 or width > tile or height > tile or rgba.len != width * height * 4) return error.InvalidPortrait;
        const slot = index / per_atlas;
        if (self.pixels[slot].len == 0) {
            self.pixels[slot] = try a.alloc(u8, side * side * 4);
            @memset(self.pixels[slot], 0);
        }
        const bytes = self.pixels[slot];
        if (width == tile and height == tile) {
            for (0..tile) |dy| {
                const to = ((y(index) + dy) * side + x(index)) * 4;
                @memcpy(bytes[to..][0 .. tile * 4], rgba[dy * tile * 4 ..][0 .. tile * 4]);
            }
            return bytes;
        }
        for (0..tile) |dy| {
            for (0..tile) |dx| {
                const from = ((dy * height / tile) * width + dx * width / tile) * 4;
                const to = ((y(index) + dy) * side + x(index) + dx) * 4;
                @memcpy(bytes[to..][0..4], rgba[from..][0..4]);
            }
        }
        return bytes;
    }
};
