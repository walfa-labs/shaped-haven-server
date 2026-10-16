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

/// Player movement speed in units per second (DESIGN.md §1).
pub const move_speed: f32 = 12.0;

/// Player collider half extent (DESIGN.md §1: 1.0 x 1.0 square).
pub const player_half_extent: f32 = 0.5;

/// Player max HP (DESIGN.md §1).
pub const player_max_hp: f32 = 100.0;

/// `n` copies of `T`, with every field at its declared default (or zero).
///
/// Used to initialize the fixed entity pools. The array-repeat operator is not
/// available in this Zig toolchain, so this is the replacement.
pub fn filledWithDefault(comptime T: type, comptime n: usize) [n]T {
    var out: [n]T = undefined;
    for (0..n) |i| {
        out[i] = std.mem.zeroInit(T, .{});
    }
    return out;
}

/// A NUL-padded 16-byte client name, as carried by `C2S_HELLO`.
pub fn nameField(name: []const u8) [16]u8 {
    var out = std.mem.zeroes([16]u8);
    const n = @min(name.len, out.len);
    @memcpy(out[0..n], name[0..n]);
    return out;
}

test "filledWithDefault repeats the default value" {
    const A = struct { x: u8 = 3, y: u16 = 4 };
    try std.testing.expectEqual(@as(usize, 4), filledWithDefault(A, 4).len);
    try std.testing.expectEqual(@as(u16, 4), filledWithDefault(A, 4)[2].y);
}

test "nameField pads with NULs and truncates" {
    const a = nameField("tester");
    try std.testing.expectEqualStrings("tester", a[0..6]);
    try std.testing.expectEqual(@as(u8, 0), a[6]);

    const b = nameField("this-name-is-far-too-long");
    try std.testing.expectEqual(@as(usize, 16), b.len);
}

test "snapshot rate divides the tick rate evenly" {
    try std.testing.expectEqual(@as(u32, 3), ticks_per_snapshot);
    try std.testing.expectEqual(@as(u32, 0), tick_hz % snapshot_hz);
}
