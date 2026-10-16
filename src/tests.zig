//! Test entry point for `zig build test`.
//!
//! Zig's test collector only walks file imports that the root module
//! semantically analyses, so every module under test is imported and used here.

const std = @import("std");
const root = @import("root.zig");
const sim = @import("sim.zig");
const wire = @import("wire.zig");
const server = @import("server.zig");
const net_opt = @import("net_opt.zig");

test "all modules are reachable" {
    try std.testing.expectEqual(root.tick_hz, 60);
    try std.testing.expectEqual(root.move_speed, 12.0);
    try std.testing.expectEqual(root.arena_half_size, 1000.0);
    try std.testing.expect(@sizeOf(wire.FrameHeader) > 0);
    try std.testing.expect(@sizeOf(server.Server) > 0);
    try std.testing.expect(@sizeOf(server.ClientConn) > 0);
    _ = net_opt.SetNoDelayError;
}
