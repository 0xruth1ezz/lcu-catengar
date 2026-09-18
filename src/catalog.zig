const std = @import("std");
const t = @import("types.zig");

/// Network connection identity is deliberately excluded. Only data affecting
/// portrait slots/labels or their versioned disk cache can invalidate the grid.
pub fn generation(cache: []const u8, champions: []const t.Champion) u64 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(cache);
    for (champions) |*champ| {
        hash.update(std.mem.asBytes(&champ.id));
        for ([_][]const u8{ champ.name.text(), champ.alias.text(), champ.asset.text() }) |field| {
            hash.update(std.mem.asBytes(&field.len));
            hash.update(field);
        }
    }
    return @max(1, hash.final());
}
