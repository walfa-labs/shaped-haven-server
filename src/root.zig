//! Shaped Haven server — package root.
//!
//! Values here come from DESIGN.md: the tick rate and snapshot rate (§1, §2),
//! the entity caps (§2) and the wire protocol constants (§5).
const std = @import("std");

/// Protocol version carried in `C2S_HELLO.proto_ver` (DESIGN.md §5).
pub const protocol_version: u8 = 1;

/// Fixed simulation rate, in ticks per second (DESIGN.md §1).
pub const tick_hz: u32 = 60;

/// Snapshot send rate, in snapshots per second (DESIGN.md §2).
pub const snapshot_hz: u32 = 20;

/// Default loopback TCP port (DESIGN.md §5).
pub const default_port: u16 = 7777;

/// Arena half extent in world units; the arena is 2 * this on each axis.
pub const arena_half_size: f32 = 1000.0;

/// Hard entity caps (DESIGN.md §2).
pub const max_players: usize = 4;
pub const max_enemies: usize = 4096;
pub const max_projectiles: usize = 2048;
pub const max_gems: usize = 4096;

/// Number of simulation ticks between snapshots.
pub const ticks_per_snapshot: u32 = tick_hz / snapshot_hz;

test "snapshot rate divides the tick rate evenly" {
    try std.testing.expectEqual(@as(u32, 3), ticks_per_snapshot);
    try std.testing.expectEqual(@as(u32, 0), tick_hz % snapshot_hz);
}
