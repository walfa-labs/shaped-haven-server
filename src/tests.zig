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
const rng = @import("rng.zig");
const spatial = @import("spatial.zig");
const enemy = @import("enemy.zig");
const weapon = @import("weapon.zig");
const combat = @import("combat.zig");
const upgrade = @import("upgrade.zig");
const gem = @import("gem.zig");
const evolve = @import("evolve.zig");
const bench = @import("bench.zig");

test "all modules are reachable" {
    try std.testing.expectEqual(root.tick_hz, 60);
    try std.testing.expectEqual(root.move_speed, 12.0);
    try std.testing.expectEqual(root.arena_half_size, 1000.0);
    try std.testing.expect(@sizeOf(wire.FrameHeader) > 0);
    try std.testing.expect(@sizeOf(server.Server) > 0);
    try std.testing.expect(@sizeOf(server.ClientConn) > 0);
    _ = net_opt.SetNoDelayError;
    _ = rng.Rng.init(0);
    try std.testing.expectEqual(spatial.cell_size, 4.0);
    try std.testing.expect(enemy.implemented.len == 2);
    try std.testing.expect(weapon.specs.len == 4);
    try std.testing.expect(combat.max_hits_per_projectile >= 1);
    try std.testing.expect(bench.default_enemies == 1000);
    try std.testing.expectEqual(@as(usize, 10), upgrade.passive_table.len);
    try std.testing.expectEqual(@as(usize, 8), upgrade.evolutions.len);
    try std.testing.expectEqual(@as(usize, 5), upgrade.synergies.len);
    try std.testing.expectEqual(@as(u16, 16), upgrade.xpForLevel(1));
    try std.testing.expectEqual(gem.small_xp, 2);
    try std.testing.expectEqual(@as(usize, 64), root.max_rifts);
    try std.testing.expect(@sizeOf(evolve.RiftPool) > 0);
}
