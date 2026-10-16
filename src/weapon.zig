//! Shaped Haven server — weapon table (DESIGN.md §3).
//!
//! The one place the weapon numbers live: the four base weapons across their
//! eight levels, and the eight evolutions a level-8 weapon fuses into with its
//! named passive. A later phase changes values here rather than hunting through
//! the combat code.
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
//!
//! Evolutions are a third family: they keep their base weapon's shape (an
//! evolved sword is still an arc, an evolved bow still travels) but carry the
//! extra behaviour fields below, which the combat code reads.

const std = @import("std");
const root = @import("root.zig");
const wire = @import("wire.zig");

pub const Id = wire.WeaponId;
pub const Shape = wire.ProjShape;

fn deg(degrees: f32) f32 {
    return degrees * std.math.pi / 180.0;
}

/// One weapon at one level.
pub const Spec = struct {
    /// Item id: a base weapon (0..3) or an evolution (32..39).
    id: u8,
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

    /// Projectile weapons: arrows/bullets fired per shot (DESIGN.md §3 "count").
    count: u8 = 1,
    /// Projectile weapons: total spread between the outermost projectiles.
    spread_rad: f32 = 0.0,
    /// Arc weapons: extra simultaneous rear slashes (Sword L4+).
    rear_slash: u8 = 0,
    /// Arc weapons: slashes fired per cycle (Sword L8 fires 2).
    slashes_per_cycle: u8 = 1,
    /// Arc weapons: extra knockback impulse (Axe L4+).
    knockback_bonus: f32 = 0.0,
    /// Arc weapons: the swing hits twice (Axe L8).
    hits_twice: u8 = 0,
    /// Projectile weapons: ricochets off the arena bounds (Bow L4+).
    ricochet: u8 = 0,
    /// Projectile weapons: every Nth shot explodes (Gun L4+).
    explosive_every: u8 = 0,
    explosive_radius: f32 = 0.0,
    explosive_mult: f32 = 1.0,

    // Evolution behaviour (DESIGN.md §3). All zero for the base weapons.
    /// Gravity Cleaver: pull hit enemies this far inward.
    pull_inward: f32 = 0.0,
    /// Gravity Cleaver: ground rift left by the sweep.
    rift_dps: f32 = 0.0,
    rift_radius: f32 = 0.0,
    rift_ticks: u16 = 0,
    /// Juggernaut Halberd: temporary shield per enemy hit.
    shield_per_hit: f32 = 0.0,
    shield_cap: f32 = 0.0,
    /// Storm Volley: sub-arrows spawned on first enemy impact.
    split_count: u8 = 0,
    split_damage_mult: f32 = 1.0,
    /// Vulcan Minigun: stacking damage-taken debuff.
    debuff_per_stack: f32 = 0.0,
    debuff_cap: f32 = 0.0,
    /// Cryo Flechette: slow, freeze and shatter.
    slow_mult: f32 = 0.0,
    slow_ticks: u16 = 0,
    freeze_stacks: u8 = 0,
    freeze_ticks: u16 = 0,
    shatter_damage: f32 = 0.0,
    shatter_radius: f32 = 0.0,
    /// Phase Katana: forward dash with invulnerability.
    dash_distance: f32 = 0.0,
    dash_invuln_ticks: u16 = 0,
};

/// A spec with every field at its zero value, for default-initializing the
/// projectile pool's per-projectile spec array.
pub const zero_spec: Spec = .{
    .id = 0,
    .shape = .arc,
    .damage = 0.0,
    .cooldown_ticks = 0,
    .reach = 0.0,
    .arc_rad = 0.0,
    .speed = 0.0,
    .radius = 0.0,
    .pierce = 0,
    .ttl_ticks = 0,
    .knockback = 0.0,
};

pub fn secondsToTicks(seconds: f32) u16 {
    return @intFromFloat(@round(seconds * @as(f32, @floatFromInt(root.tick_hz))));
}

/// DESIGN.md §3, level 1 row of each weapon's curve.
pub const specs = [_]Spec{
    .{
        .id = @intFromEnum(Id.sword),
        .shape = .arc,
        .damage = 20.0,
        .cooldown_ticks = secondsToTicks(0.75),
        .reach = 3.5,
        .arc_rad = deg(90.0),
        .speed = 0.0,
        .radius = 0.0,
        .pierce = 99,
        .ttl_ticks = secondsToTicks(0.15),
        .knockback = 3.0,
    },
    .{
        .id = @intFromEnum(Id.axe),
        .shape = .arc,
        .damage = 45.0,
        .cooldown_ticks = secondsToTicks(1.60),
        .reach = 5.0,
        .arc_rad = deg(160.0),
        .speed = 0.0,
        .radius = 0.0,
        .pierce = 99,
        .ttl_ticks = secondsToTicks(0.35),
        .knockback = 5.0,
    },
    .{
        .id = @intFromEnum(Id.bow),
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
        .id = @intFromEnum(Id.gun),
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

// ---------------------------------------------------------------------------
// Level curves (DESIGN.md §3)
// ---------------------------------------------------------------------------

fn swordSpec(level: u8) Spec {
    var s = specs[0];
    switch (level) {
        1 => {},
        2 => s.reach = 4.4,
        3 => {
            s.damage = 30.0;
            s.cooldown_ticks = secondsToTicks(0.70);
        },
        4 => {
            s.damage = 30.0;
            s.cooldown_ticks = secondsToTicks(0.70);
            s.arc_rad = deg(120.0);
            s.rear_slash = 1;
        },
        5 => {
            s.damage = 45.0;
            s.cooldown_ticks = secondsToTicks(0.70);
            s.arc_rad = deg(120.0);
            s.rear_slash = 1;
        },
        6 => {
            s.damage = 45.0;
            s.cooldown_ticks = secondsToTicks(0.60);
            s.reach = 5.25;
            s.arc_rad = deg(120.0);
            s.rear_slash = 1;
        },
        7 => {
            s.damage = 65.0;
            s.cooldown_ticks = secondsToTicks(0.60);
            s.reach = 5.25;
            s.arc_rad = deg(150.0);
            s.rear_slash = 1;
        },
        8 => {
            s.damage = 90.0;
            s.cooldown_ticks = secondsToTicks(0.50);
            s.reach = 5.25;
            s.arc_rad = deg(150.0);
            s.rear_slash = 1;
            s.slashes_per_cycle = 2;
        },
        else => {},
    }
    return s;
}

fn axeSpec(level: u8) Spec {
    var s = specs[1];
    switch (level) {
        1 => {},
        2 => s.damage = 60.0,
        3 => {
            s.damage = 60.0;
            s.reach = 6.0;
            s.arc_rad = deg(180.0);
        },
        4 => {
            s.damage = 60.0;
            s.reach = 6.0;
            s.arc_rad = deg(270.0);
            s.knockback_bonus = 2.0;
        },
        5 => {
            s.damage = 85.0;
            s.cooldown_ticks = secondsToTicks(1.45);
            s.reach = 6.0;
            s.arc_rad = deg(270.0);
            s.knockback_bonus = 2.0;
        },
        6 => {
            s.damage = 110.0;
            s.cooldown_ticks = secondsToTicks(1.45);
            s.reach = 7.0;
            s.arc_rad = deg(270.0);
            s.knockback_bonus = 2.0;
        },
        7 => {
            s.damage = 140.0;
            s.cooldown_ticks = secondsToTicks(1.25);
            s.reach = 7.0;
            s.arc_rad = deg(270.0);
            s.knockback_bonus = 2.0;
        },
        8 => {
            s.damage = 180.0;
            s.cooldown_ticks = secondsToTicks(1.25);
            s.reach = 7.0;
            s.arc_rad = deg(360.0);
            s.knockback_bonus = 2.0;
            s.hits_twice = 1;
        },
        else => {},
    }
    return s;
}

fn bowSpec(level: u8) Spec {
    var s = specs[2];
    switch (level) {
        1 => {},
        2 => {
            s.count = 2;
            s.spread_rad = deg(15.0);
        },
        3 => {
            s.damage = 40.0;
            s.count = 2;
            s.spread_rad = deg(15.0);
            s.pierce = 3;
        },
        4 => {
            s.damage = 40.0;
            s.speed = 22.5;
            s.count = 2;
            s.spread_rad = deg(15.0);
            s.pierce = 3;
            s.ricochet = 1;
        },
        5 => {
            s.damage = 55.0;
            s.speed = 22.5;
            s.count = 3;
            s.spread_rad = deg(15.0);
            s.pierce = 3;
            s.ricochet = 1;
        },
        6 => {
            s.damage = 55.0;
            s.cooldown_ticks = secondsToTicks(0.90);
            s.speed = 22.5;
            s.count = 3;
            s.spread_rad = deg(15.0);
            s.pierce = 5;
            s.ricochet = 1;
        },
        7 => {
            s.damage = 75.0;
            s.cooldown_ticks = secondsToTicks(0.90);
            s.speed = 22.5;
            s.count = 4;
            s.spread_rad = deg(15.0);
            s.pierce = 5;
            s.ricochet = 1;
        },
        8 => {
            s.damage = 100.0;
            s.cooldown_ticks = secondsToTicks(0.90);
            s.speed = 22.5;
            s.count = 4;
            s.spread_rad = deg(15.0);
            s.pierce = 99;
            s.ricochet = 2;
        },
        else => {},
    }
    return s;
}

fn gunSpec(level: u8) Spec {
    var s = specs[3];
    switch (level) {
        1 => {},
        2 => {
            s.damage = 15.0;
            s.cooldown_ticks = secondsToTicks(0.22);
        },
        3 => {
            s.damage = 15.0;
            s.cooldown_ticks = secondsToTicks(0.22);
            s.count = 2;
        },
        4 => {
            s.damage = 15.0;
            s.cooldown_ticks = secondsToTicks(0.22);
            s.count = 2;
            s.explosive_every = 4;
            s.explosive_radius = 2.5;
            s.explosive_mult = 1.5;
        },
        5 => {
            s.damage = 20.0;
            s.cooldown_ticks = secondsToTicks(0.18);
            s.count = 2;
            s.explosive_every = 4;
            s.explosive_radius = 2.5;
            s.explosive_mult = 1.5;
        },
        6 => {
            s.damage = 25.0;
            s.cooldown_ticks = secondsToTicks(0.18);
            s.count = 2;
            s.pierce = 2;
            s.explosive_every = 4;
            s.explosive_radius = 2.5;
            s.explosive_mult = 1.5;
        },
        7 => {
            s.damage = 25.0;
            s.cooldown_ticks = secondsToTicks(0.15);
            s.count = 3;
            s.pierce = 2;
            s.explosive_every = 4;
            s.explosive_radius = 2.5;
            s.explosive_mult = 1.5;
        },
        8 => {
            s.damage = 35.0;
            s.cooldown_ticks = secondsToTicks(0.12);
            s.count = 3;
            s.pierce = 2;
            s.explosive_every = 2;
            s.explosive_radius = 2.5;
            s.explosive_mult = 1.5;
        },
        else => {},
    }
    return s;
}

fn baseSpec(id: u8, level: u8) ?Spec {
    return switch (id) {
        0 => swordSpec(level),
        1 => axeSpec(level),
        2 => bowSpec(level),
        3 => gunSpec(level),
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Evolutions (DESIGN.md §3)
// ---------------------------------------------------------------------------

/// Spec for an evolution id (32..39). `level` is ignored: an evolution is a
/// fixed fusion, not a level on a curve.
fn evolutionSpec(id: u8) ?Spec {
    const sword8 = swordSpec(8);
    const axe8 = axeSpec(8);
    const bow8 = bowSpec(8);
    const gun8 = gunSpec(8);

    var s = switch (id) {
        32 => sword8, // Vorpal Blender
        33 => sword8, // Phase Katana
        34 => axe8, // Gravity Cleaver
        35 => axe8, // Juggernaut Halberd
        36 => bow8, // Railgun Longbow
        37 => bow8, // Storm Volley
        38 => gun8, // Vulcan Minigun
        39 => gun8, // Cryo Flechette
        else => return null,
    };

    // The spec names the evolution, so the projectile can report the base
    // weapon it grew from (id - 32).
    s.id = id;

    switch (id) {
        32 => {
            // Continuous 360 degree orbital blade ring, 5.5 u radius, ticking
            // every 0.15 s for 65 damage.
            s.shape = .arc;
            s.damage = 65.0;
            s.cooldown_ticks = secondsToTicks(0.15);
            s.reach = 5.5;
            s.arc_rad = deg(360.0);
            s.ttl_ticks = secondsToTicks(0.15);
            s.knockback = 2.0;
        },
        33 => {
            // Propels the player 4.0 u forward every 1.5 s with 0.3 s
            // invulnerability, leaving a 150 damage slash wake.
            s.shape = .arc;
            s.damage = 150.0;
            s.cooldown_ticks = secondsToTicks(1.50);
            s.reach = 4.0;
            s.arc_rad = deg(180.0);
            s.ttl_ticks = secondsToTicks(0.30);
            s.dash_distance = 4.0;
            s.dash_invuln_ticks = secondsToTicks(0.30);
        },
        34 => {
            // 12.0 u radius sweep, pulls hit enemies 4.0 u inward, leaves a
            // 3.0 s ground rift dealing 40 damage/sec.
            s.shape = .arc;
            s.reach = 12.0;
            s.arc_rad = deg(360.0);
            s.pull_inward = 4.0;
            s.rift_dps = 40.0;
            s.rift_radius = 3.0;
            s.rift_ticks = secondsToTicks(3.0);
        },
        35 => {
            // Adds 300% of flat armor to base damage; each swing grants +2
            // temporary shield per enemy hit, capped at 50.
            s.shape = .arc;
            s.shield_per_hit = 2.0;
            s.shield_cap = 50.0;
        },
        36 => {
            // Instant hitscan beam, 45.0 u length and 1.2 u width, 220 damage,
            // 0.70 s cooldown, infinite pierce.
            s.shape = .ray;
            s.damage = 220.0;
            s.cooldown_ticks = secondsToTicks(0.70);
            s.reach = 45.0;
            s.speed = 0.0;
            s.radius = 0.6;
            s.pierce = 99;
            s.ttl_ticks = 1;
            s.knockback = 4.0;
        },
        37 => {
            // 12 arrows in a 360 degree nova; each splits into 2 half-damage
            // sub-arrows on first enemy impact.
            s.shape = .ray;
            s.count = 12;
            s.spread_rad = deg(360.0);
            s.split_count = 2;
            s.split_damage_mult = 0.5;
        },
        38 => {
            // 0.05 s cooldown (20 rounds/sec), 50 damage; hits apply a stacking
            // debuff of +5% damage taken, capped at +50%.
            s.shape = .circle;
            s.damage = 50.0;
            s.cooldown_ticks = secondsToTicks(0.05);
            s.count = 1;
            s.debuff_per_stack = 0.05;
            s.debuff_cap = 0.50;
        },
        39 => {
            // Bullets slow targets 40% for 2.5 s; at 5 stacks the target freezes
            // for 1.5 s and shatters on death for 120 AoE damage (3.0 u radius).
            s.shape = .circle;
            s.damage = 35.0;
            s.slow_mult = 0.40;
            s.slow_ticks = secondsToTicks(2.5);
            s.freeze_stacks = 5;
            s.freeze_ticks = secondsToTicks(1.5);
            s.shatter_damage = 120.0;
            s.shatter_radius = 3.0;
        },
        else => return null,
    }
    return s;
}

/// True for the sector weapons.
pub fn isArc(s: Spec) bool {
    return s.shape == .arc;
}

/// Spec for a weapon slot id and level.
///
/// `id` is a base weapon (0..3) at any of its eight levels, or an evolution
/// (32..39) whose spec is fixed. `null` for anything else.
pub fn specFor(id: u8, level: u8) ?Spec {
    if (id < root.max_weapons) {
        const clamped = @max(1, @min(level, root.max_weapon_level));
        return baseSpec(id, clamped);
    }
    if (id >= 32 and id < 40) return evolutionSpec(id);
    return null;
}

/// Spec for a weapon slot id at level 1.
pub fn spec(id: u8) ?Spec {
    return specFor(id, 1);
}

/// Largest pierce among the *travelling* weapons, which is what the projectile
/// hit list has to be able to hold: a projectile is spent when its pierce
/// reaches zero, so it can damage at most this many distinct enemies.
///
/// Arc weapons are excluded — their 99 pierce is a "hit everything in the
/// sector" sentinel and their record never collides. The bow's level 8 row
/// raises the travelling maximum to 99.
pub const max_projectile_hits: u8 = blk: {
    var m: u8 = 0;
    for (0..root.max_weapons) |w| {
        var level: u8 = 1;
        while (level <= root.max_weapon_level) : (level += 1) {
            const s = specFor(@intCast(w), level) orelse continue;
            if (!isArc(s)) m = @max(m, s.pierce);
        }
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
        try std.testing.expectEqual(@as(u8, @intCast(i)), s.id);
        try std.testing.expectEqual(s.damage, spec(@intCast(i)).?.damage);
    }
    try std.testing.expect(spec(9) == null);
    try std.testing.expectEqual(@as(usize, root.max_weapons), specs.len);
}

test "a projectile is spent within its pierce budget" {
    // The hit list a projectile keeps has to cover the largest travelling
    // weapon's pierce, since a spent projectile never damages another enemy.
    try std.testing.expectEqual(@as(u8, 99), max_projectile_hits);
    for (specs) |s| {
        if (isArc(s)) continue;
        try std.testing.expect(s.pierce >= 1);
        try std.testing.expect(s.ttl_ticks > 0);
        try std.testing.expect(s.speed > 0.0);
        try std.testing.expect(s.radius > 0.0);
    }
}

test "the sword's eight levels follow DESIGN.md §3" {
    const l1 = specFor(0, 1).?;
    const l2 = specFor(0, 2).?;
    const l3 = specFor(0, 3).?;
    const l4 = specFor(0, 4).?;
    const l5 = specFor(0, 5).?;
    const l6 = specFor(0, 6).?;
    const l7 = specFor(0, 7).?;
    const l8 = specFor(0, 8).?;

    try std.testing.expectEqual(@as(f32, 3.5), l1.reach);
    try std.testing.expectEqual(@as(f32, 4.4), l2.reach);
    try std.testing.expectEqual(@as(f32, 30.0), l3.damage);
    try std.testing.expectEqual(@as(u16, 42), l3.cooldown_ticks); // 0.70 s
    try std.testing.expectApproxEqAbs(deg(120.0), l4.arc_rad, 1e-6);
    try std.testing.expectEqual(@as(u8, 1), l4.rear_slash);
    try std.testing.expectEqual(@as(f32, 45.0), l5.damage);
    try std.testing.expectEqual(@as(u16, 36), l6.cooldown_ticks); // 0.60 s
    try std.testing.expectEqual(@as(f32, 5.25), l6.reach);
    try std.testing.expectEqual(@as(f32, 65.0), l7.damage);
    try std.testing.expectApproxEqAbs(deg(150.0), l7.arc_rad, 1e-6);
    try std.testing.expectEqual(@as(f32, 90.0), l8.damage);
    try std.testing.expectEqual(@as(u16, 30), l8.cooldown_ticks); // 0.50 s
    try std.testing.expectEqual(@as(u8, 2), l8.slashes_per_cycle);
}

test "the axe's eight levels follow DESIGN.md §3" {
    const l2 = specFor(1, 2).?;
    const l3 = specFor(1, 3).?;
    const l4 = specFor(1, 4).?;
    const l6 = specFor(1, 6).?;
    const l8 = specFor(1, 8).?;

    try std.testing.expectEqual(@as(f32, 60.0), l2.damage);
    try std.testing.expectEqual(@as(f32, 6.0), l3.reach);
    try std.testing.expectApproxEqAbs(deg(180.0), l3.arc_rad, 1e-6);
    try std.testing.expectApproxEqAbs(deg(270.0), l4.arc_rad, 1e-6);
    try std.testing.expectEqual(@as(f32, 2.0), l4.knockback_bonus);
    try std.testing.expectEqual(@as(f32, 110.0), l6.damage);
    try std.testing.expectEqual(@as(f32, 7.0), l6.reach);
    try std.testing.expectApproxEqAbs(deg(360.0), l8.arc_rad, 1e-6);
    try std.testing.expectEqual(@as(f32, 180.0), l8.damage);
    try std.testing.expectEqual(@as(u8, 1), l8.hits_twice);
}

test "the bow's eight levels follow DESIGN.md §3" {
    const l2 = specFor(2, 2).?;
    const l4 = specFor(2, 4).?;
    const l6 = specFor(2, 6).?;
    const l8 = specFor(2, 8).?;

    try std.testing.expectEqual(@as(u8, 2), l2.count);
    try std.testing.expectApproxEqAbs(deg(15.0), l2.spread_rad, 1e-6);
    // L2 adds the arrow; L3 raises the damage.
    try std.testing.expectEqual(@as(f32, 30.0), l2.damage);
    try std.testing.expectEqual(@as(f32, 40.0), specFor(2, 3).?.damage);
    try std.testing.expectEqual(@as(f32, 22.5), l4.speed);
    try std.testing.expectEqual(@as(u8, 1), l4.ricochet);
    try std.testing.expectEqual(@as(u8, 5), l6.pierce);
    try std.testing.expectEqual(@as(u8, 4), specFor(2, 7).?.count);
    try std.testing.expectEqual(@as(f32, 100.0), l8.damage);
    try std.testing.expectEqual(@as(u8, 99), l8.pierce);
    try std.testing.expectEqual(@as(u8, 2), l8.ricochet);
}

test "the gun's eight levels follow DESIGN.md §3" {
    const l3 = specFor(3, 3).?;
    const l4 = specFor(3, 4).?;
    const l6 = specFor(3, 6).?;
    const l8 = specFor(3, 8).?;

    try std.testing.expectEqual(@as(u8, 2), l3.count);
    try std.testing.expectEqual(@as(u8, 4), l4.explosive_every);
    try std.testing.expectEqual(@as(f32, 2.5), l4.explosive_radius);
    try std.testing.expectEqual(@as(u8, 2), l6.pierce);
    try std.testing.expectEqual(@as(u8, 3), specFor(3, 7).?.count);
    try std.testing.expectEqual(@as(f32, 35.0), l8.damage);
    try std.testing.expectEqual(@as(u16, 7), l8.cooldown_ticks); // 0.12 s
    try std.testing.expectEqual(@as(u8, 2), l8.explosive_every);
}

test "every evolution id resolves to a spec" {
    var id: u8 = 32;
    while (id < 40) : (id += 1) {
        const s = specFor(id, 8) orelse return error.MissingEvolution;
        try std.testing.expect(s.damage > 0.0);
        try std.testing.expect(s.cooldown_ticks > 0);
    }
    try std.testing.expect(specFor(40, 8) == null);
    try std.testing.expect(specFor(0xff, 8) == null);
}

test "the evolutions carry their DESIGN.md §3 behaviour fields" {
    const cleaver = specFor(34, 8).?;
    try std.testing.expectEqual(@as(f32, 12.0), cleaver.reach);
    try std.testing.expectEqual(@as(f32, 4.0), cleaver.pull_inward);
    try std.testing.expectEqual(@as(f32, 40.0), cleaver.rift_dps);

    const halberd = specFor(35, 8).?;
    try std.testing.expectEqual(@as(f32, 2.0), halberd.shield_per_hit);
    try std.testing.expectEqual(@as(f32, 50.0), halberd.shield_cap);

    const railgun = specFor(36, 8).?;
    try std.testing.expectEqual(@as(f32, 220.0), railgun.damage);
    try std.testing.expectEqual(@as(f32, 45.0), railgun.reach);
    try std.testing.expectEqual(Shape.ray, railgun.shape);

    const volley = specFor(37, 8).?;
    try std.testing.expectEqual(@as(u8, 12), volley.count);
    try std.testing.expectEqual(@as(u8, 2), volley.split_count);

    const minigun = specFor(38, 8).?;
    try std.testing.expectEqual(@as(f32, 50.0), minigun.damage);
    try std.testing.expectEqual(@as(u16, 3), minigun.cooldown_ticks); // 0.05 s

    const cryo = specFor(39, 8).?;
    try std.testing.expectEqual(@as(f32, 0.40), cryo.slow_mult);
    try std.testing.expectEqual(@as(u8, 5), cryo.freeze_stacks);
    try std.testing.expectEqual(@as(f32, 120.0), cryo.shatter_damage);
}
