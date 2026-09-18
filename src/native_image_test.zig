const std = @import("std");
const native = @import("native_sdk");

test "cached image fingerprints persist without updates and invalidate on changed pixels" {
    const a = std.testing.allocator;
    const harness = try native.TestHarness().create(a, .{ .size = .{ .width = 64, .height = 64 } });
    defer harness.destroy(a);
    const red = [_]u8{ 255, 0, 0, 255 };
    const blue = [_]u8{ 0, 0, 255, 255 };
    try harness.runtime.registerCanvasImage(7, 1, 1, &red);
    const first = harness.runtime.registeredCanvasImages()[0].content_fingerprint;
    try std.testing.expect(first != 0);
    try std.testing.expectEqual(first, harness.runtime.registeredCanvasImages()[0].content_fingerprint);
    try harness.runtime.registerCanvasImage(7, 1, 1, &red);
    try std.testing.expectEqual(first, harness.runtime.registeredCanvasImages()[0].content_fingerprint);
    try harness.runtime.registerCanvasImage(7, 1, 1, &blue);
    try std.testing.expect(first != harness.runtime.registeredCanvasImages()[0].content_fingerprint);
    try harness.runtime.registerCanvasImage(8, 1, 1, &red);
    try std.testing.expect(harness.runtime.unregisterCanvasImage(7));
    const retained = harness.runtime.registeredCanvasImages()[0];
    try std.testing.expectEqual(@as(u64, 8), retained.id);
    try std.testing.expectEqual(first, retained.content_fingerprint);
}
