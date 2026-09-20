const std = @import("std");
const t = @import("types.zig");

fn phase(s: *const t.Snapshot, name: []const u8) bool {
    return std.mem.eql(u8, s.phase.text(), name);
}

pub fn connectionLabel(s: *const t.Snapshot) []const u8 {
    if (s.connected) return "客户端已连接";
    return switch (s.connection) {
        .waiting_client => "等待客户端启动",
        .connecting => "正在连接客户端",
        .reconnecting => "正在恢复连接",
        .authorizing => "正在验证连接权限",
        .permission_required => "连接助手启动被取消",
        .helper_missing, .helper_failed, .failed => "连接暂不可用",
    };
}

pub fn phaseLabel(s: *const t.Snapshot) []const u8 {
    if (!s.connected) return "";
    const labels = .{
        .{ "None", "空闲" },
        .{ "Lobby", "房间内" },
        .{ "Matchmaking", "匹配中" },
        .{ "ReadyCheck", "等待接受" },
        .{ "ChampSelect", "选择英雄" },
        .{ "GameStart", "进入对局" },
        .{ "InProgress", "对局中" },
        .{ "Reconnect", "等待重返对局" },
        .{ "WaitingForStats", "等待结算" },
        .{ "PreEndOfGame", "等待结算" },
        .{ "EndOfGame", "对局结束" },
        .{ "TerminatedInError", "对局已中断" },
    };
    inline for (labels) |label| if (phase(s, label[0])) return label[1];
    return "对局状态待同步";
}

pub fn connectionNotice(s: *const t.Snapshot) []const u8 {
    if (s.connected) return "";
    return switch (s.connection) {
        .connecting, .waiting_client => "",
        .reconnecting => "正在恢复连接，自动功能暂不可用。你的偏好会保留。",
        .authorizing => "正在启动连接助手并验证管理员权限，完成后将自动连接客户端。",
        .permission_required => "Windows 取消了连接助手的启动。请点击「授权连接」重试；如有系统确认，请允许助手运行。",
        .helper_missing => "缺少连接助手。请将 catengar-auth.exe 放在主程序旁，再重新连接。",
        .helper_failed => "连接助手暂时不可用，正在自动重试。也可点击「授权连接」立即重试。",
        .failed => "暂时无法连接客户端。请确认客户端已启动后重试；仍无响应时重新打开工具。",
    };
}
