//! Shaped Haven server — weapon table (DESIGN.md §3).
//!
//! Phase 2 implements the level 1 row of each of the four weapons and nothing
//! above it: no level curves, no evolutions, no passives. The table is the one
//! place those numbers live, so a later phase changes values here rather than
//! hunting through the combat code.
//!
//! Two families, and the split decides how a weapon damages:
//!
//! * **Arc weapons** (sword, axe) test a sector around the player the instant
//!   the cooldown elapses. They emit a short-lived `arc` projectile record as
//!   well, but only so the client can draw the swing — the damage is already
//!   done and the record never collides.
//! * **Projectile weapons** (bow, gun) spawn a travelling record that damages
//!   whatever it overlaps as it moves, until its pierce or its lifetime runs
//!   out.

const std = @import("std");
const root = @import("root.zig");
const wire = @import("wire.zig");

pub const Id = wire.WeaponId;
pub const Shape = wire.ProjShape;

/// One weapon at one level.
pub const Spec = struct {
    id: Id,
    /// Wire shape used for this weapon's records.
    shape: Shape,
    damage: f32,
    cooldown_ticks: u16,
    /// Arc weapons: distance from the player the sector reaches.
    reach: f32,
    /// Arc weapons: full width of the sector, in radians.
    arc_rad: f32,
    /// Projectile weapons: travel speed in units per second.
    speed: f32,
    /// Projectile weapons: collision radius.
    radius: f32,
    /// Projectile weapons: how many enemies it can damage before it is spent.
    pierce: u8,
    /// Ticks the record lives. For arc weapons this is the sweep's visual
    /// duration (DESIGN.md §3 "0.15 s dur" / "0.35 s dur"); for projectiles it
    /// is DESIGN.md's "dur".
    ttl_ticks: u16,
    /// Knockback impulse applied along the hit direction, in units per second.
    ///
    /// DESIGN.md only names a knockback figure in the Axe L4 upgrade ("adds
    /// 2.0 u knockback impulse"), so the level 1 values here are this phase's
    /// choice: enough to shove a swarmer off the player, small enough that it
    /// cannot fling an enemy across the arena.
    knockback: f32,
};

pub fn secondsToTicks(seconds: f32) u16 {
    return @intFromFloat(@round(seconds * @as(f32, @floatFromInt(root.tick_hz))));
}

/// DESIGN.md §3, level 1 row of each weapon's curve.
pub const specs = [_]Spec{
    .{
        .id = .sword,
        .shape = .arc,
        .damage = 20.0,
        .cooldown_ticks = secondsToTicks(0.75),
        .reach = 3.5,
        .arc_rad = 90.0 * std.math.pi / 180.0,
        .speed = 0.0,
        .radius = 0.0,
        .pierce = 99,
        .ttl_ticks = secondsToTicks(0.15),
        .knockback = 3.0,
    },
    .{
        .id = .axe,
        .shape = .arc,
        .damage = 45.0,
        .cooldown_ticks = secondsToTicks(1.60),
        .reach = 5.0,
        .arc_rad = 160.0 * std.math.pi / 180.0,
        .speed = 0.0,
        .radius = 0.0,
        .pierce = 99,
        .ttl_ticks = secondsToTicks(0.35),
        .knockback = 5.0,
    },
    .{
        .id = .bow,
        .shape = .ray,
        .damage = 30.0,
        .cooldown_ticks = secondsToTicks(1.10),
        .reach = 0.0,
        .arc_rad = 0.0,
        .speed = 18.0,
        .radius = 0.4,
        .pierce = 2,
        .ttl_ticks = secondsToTicks(2.0),
        .knockback = 2.0,
    },
    .{
        .id = .gun,
        .shape = .circle,
        .damage = 12.0,
        .cooldown_ticks = secondsToTicks(0.25),
        .reach = 0.0,
        .arc_rad = 0.0,
        .speed = 28.0,
        .radius = 0.25,
        .pierce = 1,
        .ttl_ticks = secondsToTicks(1.2),
        .knockback = 1.0,
    },
};

/// True for the sector weapons.
pub fn isArc(s: Spec) bool {
    return s.shape == .arc;
}

/// Spec for a weapon slot id, or `null` when the id names no weapon.
pub fn spec(id: u8) ?Spec {
    for (specs) |s| {
        if (@intFromEnum(s.id) == id) return s;
    }
    return null;
}

/// Largest pierce among the *travelling* weapons, which is what the projectile
/// hit list has to be able to hold: a projectile is spent when its pierce
/// reaches zero, so it can damage at most this many distinct enemies.
///
/// Arc weapons are excluded — their 99 pierce is a "hit everything in the
/// sector" sentinel and their record never collides.
pub const max_projectile_hits: u8 = blk: {
    var m: u8 = 0;
    for (specs) |s| {
        if (!isArc(s)) m = @max(m, s.pierce);
    }
    break :blk m;
};

test "the sword matches DESIGN.md §3 level 1" {
    const s = spec(@intFromEnum(Id.sword)).?;
    try std.testing.expectEqual(@as(f32, 20.0), s.damage);
    try std.testing.expectEqual(@as(u16, 45), s.cooldown_ticks);
    try std.testing.expectEqual(@as(f32, 3.5), s.reach);
    try std.testing.expectApproxEqAbs(std.math.pi / 2.0, s.arc_rad, 1e-6);
    try std.testing.expectEqual(@as(u8, 99), s.pierce);
    try std.testing.expectEqual(Shape.arc, s.shape);
    try std.testing.expect(isArc(s));
}

test "the axe matches DESIGN.md §3 level 1" {
    const s = spec(@intFromEnum(Id.axe)).?;
    try std.testing.expectEqual(@as(f32, 45.0), s.damage);
    try std.testing.expectEqual(@as(u16, 96), s.cooldown_ticks);
    try std.testing.expectEqual(@as(f32, 5.0), s.reach);
    try std.testing.expectApproxEqAbs(160.0 * std.math.pi / 180.0, s.arc_rad, 1e-6);
    try std.testing.expectEqual(@as(u8, 99), s.pierce);
    try std.testing.expect(isArc(s));
}

test "the bow matches DESIGN.md §3 level 1" {
    const s = spec(@intFromEnum(Id.bow)).?;
    try std.testing.expectEqual(@as(f32, 30.0), s.damage);
    try std.testing.expectEqual(@as(u16, 66), s.cooldown_ticks);
    try std.testing.expectEqual(@as(f32, 18.0), s.speed);
    try std.testing.expectEqual(@as(f32, 0.4), s.radius);
    try std.testing.expectEqual(@as(u8, 2), s.pierce);
    try std.testing.expectEqual(@as(u16, 120), s.ttl_ticks);
    try std.testing.expectEqual(Shape.ray, s.shape);
    try std.testing.expect(!isArc(s));
}

test "the gun matches DESIGN.md §3 level 1" {
    const s = spec(@intFromEnum(Id.gun)).?;
    try std.testing.expectEqual(@as(f32, 12.0), s.damage);
    try std.testing.expectEqual(@as(u16, 15), s.cooldown_ticks);
    try std.testing.expectEqual(@as(f32, 28.0), s.speed);
    try std.testing.expectEqual(@as(f32, 0.25), s.radius);
    try std.testing.expectEqual(@as(u8, 1), s.pierce);
    try std.testing.expectEqual(@as(u16, 72), s.ttl_ticks);
    try std.testing.expectEqual(Shape.circle, s.shape);
    try std.testing.expect(!isArc(s));
}

test "every weapon is reachable by its slot id" {
    for (specs, 0..) |s, i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), @intFromEnum(s.id));
        try std.testing.expectEqual(s.damage, spec(@intCast(i)).?.damage);
    }
    try std.testing.expect(spec(9) == null);
    try std.testing.expectEqual(@as(usize, root.max_weapons), specs.len);
}

test "a projectile is spent within its pierce budget" {
    // The hit list a projectile keeps has to cover the largest travelling
    // weapon's pierce, since a spent projectile never damages another enemy.
    try std.testing.expectEqual(@as(u8, 2), max_projectile_hits);
    for (specs) |s| {
        if (isArc(s)) continue;
        try std.testing.expect(s.pierce >= 1);
        try std.testing.expect(s.ttl_ticks > 0);
        try std.testing.expect(s.speed > 0.0);
        try std.testing.expect(s.radius > 0.0);
    }
}
