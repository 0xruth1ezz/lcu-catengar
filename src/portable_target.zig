const std = @import("std");
const builtin = @import("builtin");

/// Every shipped executable must work on an ordinary Windows x64 CPU, even
/// when built by a newer AMD/Intel CI runner. In particular SSE4a is AMD-only.
pub fn requireBaseline() void {
    comptime {
        if (builtin.cpu.arch != .x86_64 or builtin.os.tag != .windows)
            @compileError("Catengar portable releases require -Dtarget=x86_64-windows-gnu -Dcpu=baseline");
        const baseline = std.Target.Cpu.baseline(.x86_64, builtin.os);
        if (!builtin.cpu.features.eql(baseline.features))
            @compileError("Catengar portable releases require -Dcpu=baseline; native/host CPU instructions are not portable");
    }
}

test "distributed executables use the generic Windows x64 baseline" {
    requireBaseline();
    try std.testing.expect(!builtin.cpu.hasAny(.x86, &.{ .sse4a, .avx, .avx2, .avx512f }));
}
