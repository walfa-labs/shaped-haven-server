//! Shaped Haven server — package root.
//!
//! Values here come from DESIGN.md: the tick rate and snapshot rate (§1, §2),
//! the entity caps (§2) and the wire protocol constants (§5).
const std = @import("std");

/// Protocol version carried in `C2S_HELLO.proto_ver` (DESIGN.md §5).
pub const protocol_version: u8 = 2;

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

/// Weapon slots per player (DESIGN.md §2 `weapons: [4]WeaponSlot`).
pub const max_weapons: usize = 4;

/// Passive slots per player (DESIGN.md §2 `passives: [10]u8`).
pub const max_passives: usize = 10;

/// Live ground rifts a Gravity Cleaver sweep can leave at once.
pub const max_rifts: usize = 64;

/// Highest weapon level (DESIGN.md §3: eight levels per weapon).
pub const max_weapon_level: u8 = 8;

/// Base XP gem pickup radius in world units (DESIGN.md §1).
pub const xp_pickup_radius: f32 = 3.0;

/// Interest-management radius in world units (PROTOCOL.md "Interest
/// management"). A snapshot — full or delta — carries only entities within
/// this distance of the receiving player. It is sent to the client in
/// `S2C_WELCOME` as a `u16`.
///
/// The orthographic viewport covers 80 x 45 units (DESIGN.md §1), so this is
/// sized to cover the screen: a circle of this radius reaches the viewport's
/// left and right edges (40 units) and its top and bottom (22.5) with margin,
/// while leaving the far corners — the least valuable, hardest-to-see part of
/// the screen — outside the radius. A smaller radius is what makes the phase-4
/// bandwidth budget reachable at all: the wire carries only this neighbourhood,
/// not the whole horde.
pub const interest_radius: f32 = 40.0;

/// Number of simulation ticks between snapshots.
pub const ticks_per_snapshot: u32 = tick_hz / snapshot_hz;

/// Wire budget for one delta snapshot frame, in bytes.
///
/// DESIGN.md §6 sets the phase-4 definition of done at *"bandwidth stays under
/// 25 KB/s during a 2,500-enemy 20:00 stress test"*. At the 20 Hz snapshot rate
/// that is 1,250 bytes per snapshot; this takes 80% of it, so a single frame —
/// not merely the mean of many — stays inside the budget, with the remainder
/// left as headroom for the full snapshots a connection starts on and for the
/// `spawned`/`destroyed` records, which are never dropped to fit.
pub const snapshot_budget_bytes: usize = 1000;

/// Player movement speed in units per second (DESIGN.md §1).
pub const move_speed: f32 = 12.0;

/// Player collider half extent (DESIGN.md §1: 1.0 x 1.0 square).
pub const player_half_extent: f32 = 0.5;

/// Player max HP (DESIGN.md §1).
pub const player_max_hp: f32 = 100.0;

/// `n` copies of `T`, with every field at its declared default (or zero).
///
/// Used to initialize the fixed entity pools. The array-repeat operator is not
/// available in this Zig toolchain, so this is the replacement. Struct field
/// defaults are evaluated at comptime, which is why the big flat arrays use
/// `@splat` directly instead: filling 4096 elements one at a time blows the
/// compiler's evaluation branch quota.
pub fn filledWithDefault(comptime T: type, comptime n: usize) [n]T {
    @setEvalBranchQuota(20000);
    var out: [n]T = undefined;
    for (0..n) |i| {
        out[i] = std.mem.zeroInit(T, .{});
    }
    return out;
}

/// `n` copies of a comptime-known `value`.
///
/// Cheaper than `filledWithDefault` for a type whose `zeroInit` walks a large
/// field list, because it copies one value rather than evaluating every field's
/// default.
pub fn repeated(comptime T: type, comptime n: usize, comptime value: T) [n]T {
    @setEvalBranchQuota(20000);
    var out: [n]T = undefined;
    for (0..n) |i| out[i] = value;
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
