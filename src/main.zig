const std = @import("std");
const server = @import("shaped_haven_server");

pub fn main(_: std.process.Init) !void {
    std.debug.print(
        "shaped-haven-server — protocol v{d}\n" ++
            "  tick rate: {d} Hz\n" ++
            "  snapshots: {d} Hz\n" ++
            "  listen:    127.0.0.1:{d}\n" ++
            "  arena:     {d} x {d} units\n",
        .{
            server.protocol_version,
            server.tick_hz,
            server.snapshot_hz,
            server.default_port,
            @as(i32, @intFromFloat(server.arena_half_size * 2)),
            @as(i32, @intFromFloat(server.arena_half_size * 2)),
        },
    );
}

test "server constants match the design document" {
    try std.testing.expectEqual(@as(u32, 60), server.tick_hz);
    try std.testing.expectEqual(@as(u32, 20), server.snapshot_hz);
    try std.testing.expectEqual(@as(u16, 7777), server.default_port);
}
