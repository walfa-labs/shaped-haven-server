//! Shaped Haven server — enemy pool, archetypes and the spawn formula.
//!
//! DESIGN.md §2 fixes the enemy field list and §4 the Tier 1 archetypes and the
//! spawn curve. Phase 2 implements the two Tier 1 archetypes; the Tier 2 and
//! Tier 3 rows of §4 arrive with the difficulty curve in phase 4.
//!
//! Layout is structure-of-arrays: one flat array per field, indexed by the
//! enemy's slot, with a live count at the front. Slots are dense — a dead enemy
//! is removed by moving the last live enemy into its place — so iterating the
//! pool costs the live count, not the 4096-entry cap. Ids are stored
//! separately and never reused, so a swap-remove is invisible on the wire.

const std = @import("std");
const root = @import("root.zig");
const wire = @import("wire.zig");
const rng = @import("rng.zig");

pub const Archetype = wire.EnemyArchetype;

/// Largest radius among the implemented archetypes. Broadphase queries add it
/// to a weapon's reach so an enemy whose *edge* overlaps is still a candidate.
pub const max_radius: f32 = 0.5;

/// Per-archetype stats (DESIGN.md §4, Tier 1 rows).
pub const Stats = struct {
    hp: f32,
    move_speed: f32,
    contact_dmg: f32,
    radius: f32,
    /// Simulation tick at which the archetype unlocks (DESIGN.md §4 "Tier &
    /// unlock"). Circle T1 is available from the first tick.
    unlock_tick: u32,
};

/// Stats for an archetype, or `null` for one this phase does not implement.
///
/// Returning `null` rather than a stand-in keeps an unimplemented archetype out
/// of the world instead of quietly simulating it as a swarmer.
pub fn stats(a: Archetype) ?Stats {
    return switch (a) {
        .circle_t1 => .{
            .hp = 15.0,
            .move_speed = 4.5,
            .contact_dmg = 5.0,
            .radius = 0.5,
            .unlock_tick = 0,
        },
        .triangle_t1 => .{
            .hp = 10.0,
            .move_speed = 7.0,
            .contact_dmg = 8.0,
            .radius = 0.5,
            .unlock_tick = 90 * root.tick_hz, // 1:30
        },
        else => null,
    };
}

/// Archetypes this phase can spawn.
pub const implemented = [_]Archetype{ .circle_t1, .triangle_t1 };

/// Darter behaviour constants (DESIGN.md §4, Triangle T1).
pub const darter = struct {
    /// Range at which the darter stops and winds up.
    pub const pause_range: f32 = 10.0;
    /// Ticks spent paused at `pause_range`.
    pub const pause_ticks: u16 = 24; // 0.4 s
    /// Speed of the lunge.
    pub const lunge_speed: f32 = 15.0;
    /// Ticks a lunge lasts. DESIGN.md fixes the pause and the lunge speed but
    /// not the lunge length; 0.5 s at 15 u/s covers 7.5 units, which is enough
    /// to cross the gap it paused at without overshooting past the player.
    pub const lunge_ticks: u16 = 30;
};

/// Enemy AI states. Only the darter leaves `pursue`.
pub const AiState = enum(u8) {
    pursue = 0,
    windup = 1,
    lunge = 2,
};

/// Ticks between contact hits from the same enemy.
///
/// DESIGN.md §4 gives a contact damage *value* but no cadence; applying it
/// every tick would be 60 hits a second and would empty any health bar
/// instantly. Two hits a second is the cadence this phase uses.
pub const contact_cooldown_ticks: u16 = 30;

/// Ticks a knockback impulse takes to decay to nothing (0.90 per tick).
pub const knockback_decay: f32 = 0.90;

// ---------------------------------------------------------------------------
// Spawn formula (DESIGN.md §4)
// ---------------------------------------------------------------------------

/// The formula is evaluated once per second.
pub const spawn_interval_ticks: u32 = root.tick_hz;

/// Wave surge cadence: every 120 s, for 15 s (DESIGN.md §4).
pub const surge_period_ticks: u32 = 120 * root.tick_hz;
pub const surge_duration_ticks: u32 = 15 * root.tick_hz;
pub const surge_multiplier: f32 = 2.5;
/// Half-width of each of the two opposing pincer arcs a surge spawns into.
pub const surge_arc_rad: f32 = 30.0 * std.math.pi / 180.0;

/// Spawn ring around the alive players' centroid (DESIGN.md §4).
pub const spawn_min_radius: f32 = 48.0;
pub const spawn_max_radius: f32 = 56.0;

/// `E_max(t) = min(4096, floor(40 + 35t + 4t²))`, `t` in elapsed minutes.
pub fn activeCap(t_minutes: f32) usize {
    const raw = 40.0 + 35.0 * t_minutes + 4.0 * t_minutes * t_minutes;
    const capped = @min(raw, @as(f32, @floatFromInt(root.max_enemies)));
    return @intFromFloat(@floor(capped));
}

/// `R(t) = (3.0 + 2.2t + 0.35t²) × (1 + 0.5(P − 1))` enemies per second.
pub fn spawnRate(t_minutes: f32, player_count: u8) f32 {
    const base = 3.0 + 2.2 * t_minutes + 0.35 * t_minutes * t_minutes;
    const party = 1.0 + 0.5 * (@as(f32, @floatFromInt(player_count)) - 1.0);
    return base * party;
}

/// True inside a wave surge window.
pub fn surgeActive(tick: u32) bool {
    if (tick < surge_period_ticks) return false;
    return tick % surge_period_ticks < surge_duration_ticks;
}

/// Pick an archetype for a spawn at `tick`.
///
/// DESIGN.md §4 gives unlock times but no mix ratio, so once both Tier 1
/// archetypes are unlocked the choice is an even 50/50.
pub fn pickArchetype(r: *rng.Rng, tick: u32) Archetype {
    const triangle = stats(.triangle_t1).?.unlock_tick;
    if (tick < triangle) return .circle_t1;
    return if (r.below(2) == 0) .circle_t1 else .triangle_t1;
}

/// The pincer axis for one spawn event, or `null` when no surge is running.
///
/// Drawn once per event rather than once per enemy: a surge is supposed to
/// concentrate a wave into two opposing arcs, which only happens if every enemy
/// in that wave is measured from the same axis.
pub fn surgeAxis(r: *rng.Rng, tick: u32) ?f32 {
    if (!surgeActive(tick)) return null;
    return r.range(0.0, 2.0 * std.math.pi);
}

/// Angle to spawn one enemy at, in `[0, 2π)`.
///
/// With no surge axis this is a plain uniform angle. Inside a surge it is the
/// axis plus 0 or π — the two opposing pincer arms — plus up to half of the 30°
/// arc (DESIGN.md §4).
pub fn spawnAngle(r: *rng.Rng, axis: ?f32) f32 {
    const two_pi = 2.0 * std.math.pi;
    const base = axis orelse return r.range(0.0, two_pi);
    const opposing = if (r.below(2) == 0) @as(f32, 0.0) else std.math.pi;
    return @mod(base + opposing + r.range(-surge_arc_rad, surge_arc_rad), two_pi);
}

// ---------------------------------------------------------------------------
// Pool
// ---------------------------------------------------------------------------

pub const Pool = struct {
    /// Live enemies, all in slots `[0, count)`.
    count: usize = 0,
    /// Next entity id. Ids are never reused, so a swap-remove cannot make the
    /// client mistake one enemy for another.
    next_id: u32 = 1,

    id: [root.max_enemies]u32 = @splat(0),
    archetype: [root.max_enemies]u8 = @splat(0),
    elite_mask: [root.max_enemies]u8 = @splat(0),
    ai_state: [root.max_enemies]u8 = @splat(0),
    /// Ticks left in the current AI state (darter wind-up and lunge).
    ai_timer: [root.max_enemies]u16 = @splat(0),
    /// Ticks until this enemy may land another contact hit.
    contact_cd: [root.max_enemies]u16 = @splat(0),
    pos: [root.max_enemies][2]f32 = @splat(.{ 0.0, 0.0 }),
    /// Velocity the AI asked for this tick.
    vel: [root.max_enemies][2]f32 = @splat(.{ 0.0, 0.0 }),
    /// Knockback impulse, decayed every tick and added on top of `vel`.
    kb: [root.max_enemies][2]f32 = @splat(.{ 0.0, 0.0 }),
    hp: [root.max_enemies]f32 = @splat(0.0),
    max_hp: [root.max_enemies]f32 = @splat(0.0),
    radius: [root.max_enemies]f32 = @splat(0.0),
    contact_dmg: [root.max_enemies]f32 = @splat(0.0),
    move_speed: [root.max_enemies]f32 = @splat(0.0),

    /// Reserve a slot. Returns `null` when the pool is full or the archetype is
    /// not implemented in this phase — a full pool must degrade, not crash.
    pub fn spawn(self: *Pool, archetype: Archetype, pos: [2]f32) ?usize {
        if (self.count >= root.max_enemies) return null;
        const s = stats(archetype) orelse return null;

        const i = self.count;
        self.id[i] = self.next_id;
        self.next_id +%= 1;
        self.archetype[i] = @intFromEnum(archetype);
        self.elite_mask[i] = 0;
        self.ai_state[i] = @intFromEnum(AiState.pursue);
        self.ai_timer[i] = 0;
        self.contact_cd[i] = 0;
        self.pos[i] = pos;
        self.vel[i] = .{ 0.0, 0.0 };
        self.kb[i] = .{ 0.0, 0.0 };
        self.hp[i] = s.hp;
        self.max_hp[i] = s.hp;
        self.radius[i] = s.radius;
        self.contact_dmg[i] = s.contact_dmg;
        self.move_speed[i] = s.move_speed;
        self.count += 1;
        return i;
    }

    /// Remove slot `i` by moving the last live enemy into it.
    ///
    /// Every per-entity array is copied, so a field added later is carried
    /// across automatically; only the pool-wide counters are skipped.
    pub fn swapRemove(self: *Pool, i: usize) void {
        std.debug.assert(i < self.count);
        const last = self.count - 1;
        if (i != last) {
            inline for (@typeInfo(Pool).@"struct".field_names) |name| {
                if (comptime !std.mem.eql(u8, name, "count") and
                    !std.mem.eql(u8, name, "next_id"))
                {
                    @field(self, name)[i] = @field(self, name)[last];
                }
            }
        }
        self.count -= 1;
    }

    /// Compact away every enemy at or below zero HP. Returns the kill count.
    pub fn reapDead(self: *Pool) usize {
        var killed: usize = 0;
        var i: usize = 0;
        while (i < self.count) {
            if (self.hp[i] <= 0.0) {
                self.swapRemove(i);
                killed += 1;
            } else {
                i += 1;
            }
        }
        return killed;
    }

    /// Apply `amount` damage and `impulse` knockback along `dir`. Returns true
    /// when this hit killed the enemy.
    pub fn applyHit(self: *Pool, i: usize, amount: f32, dir: [2]f32, impulse: f32) bool {
        self.hp[i] -= amount;
        self.kb[i][0] += dir[0] * impulse;
        self.kb[i][1] += dir[1] * impulse;
        return self.hp[i] <= 0.0;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Tier 1 stats match DESIGN.md §4" {
    const swarm = stats(.circle_t1).?;
    try std.testing.expectEqual(@as(f32, 15.0), swarm.hp);
    try std.testing.expectEqual(@as(f32, 4.5), swarm.move_speed);
    try std.testing.expectEqual(@as(f32, 5.0), swarm.contact_dmg);
    try std.testing.expectEqual(@as(f32, 0.5), swarm.radius);
    try std.testing.expectEqual(@as(u32, 0), swarm.unlock_tick);

    const darter_stats = stats(.triangle_t1).?;
    try std.testing.expectEqual(@as(f32, 10.0), darter_stats.hp);
    try std.testing.expectEqual(@as(f32, 7.0), darter_stats.move_speed);
    try std.testing.expectEqual(@as(f32, 8.0), darter_stats.contact_dmg);
    try std.testing.expectEqual(@as(f32, 0.5), darter_stats.radius);
    try std.testing.expectEqual(@as(u32, 90 * 60), darter_stats.unlock_tick);

    // Later tiers are not implemented in this phase.
    try std.testing.expect(stats(.circle_t2) == null);
    try std.testing.expect(stats(.boss) == null);
    try std.testing.expectEqual(@as(f32, 0.5), max_radius);
}

test "the active cap follows DESIGN.md §4" {
    try std.testing.expectEqual(@as(usize, 40), activeCap(0.0));
    try std.testing.expectEqual(@as(usize, 79), activeCap(1.0));
    try std.testing.expectEqual(@as(usize, 244), activeCap(4.0));
    try std.testing.expectEqual(@as(usize, 790), activeCap(10.0));
    // Capped at the pool size however far the curve runs.
    try std.testing.expectEqual(root.max_enemies, activeCap(1000.0));
}

test "the spawn rate follows DESIGN.md §4" {
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), spawnRate(0.0, 1), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 4.5), spawnRate(0.0, 2), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 7.5), spawnRate(0.0, 4), 1e-5);
    // 3.0 + 2.2 + 0.35 at one minute.
    try std.testing.expectApproxEqAbs(@as(f32, 5.55), spawnRate(1.0, 1), 1e-4);
}

test "wave surges run for 15 s every 2 minutes" {
    try std.testing.expect(!surgeActive(0));
    try std.testing.expect(!surgeActive(120 * 60 - 1));
    try std.testing.expect(surgeActive(120 * 60));
    try std.testing.expect(surgeActive(120 * 60 + 15 * 60 - 1));
    try std.testing.expect(!surgeActive(120 * 60 + 15 * 60));
    try std.testing.expect(surgeActive(240 * 60));
}

test "the triangle archetype unlocks at 1:30" {
    var r = rng.Rng.init(3);
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        try std.testing.expectEqual(Archetype.circle_t1, pickArchetype(&r, 89 * 60));
    }
    // After the unlock both archetypes appear.
    var circles: usize = 0;
    var triangles: usize = 0;
    i = 0;
    while (i < 200) : (i += 1) {
        switch (pickArchetype(&r, 90 * 60)) {
            .circle_t1 => circles += 1,
            .triangle_t1 => triangles += 1,
            else => unreachable,
        }
    }
    try std.testing.expect(circles > 60 and triangles > 60);
}

test "surge spawn angles fall into two opposing arcs" {
    var r = rng.Rng.init(11);
    const tick = 120 * 60;
    const pi = std.math.pi;

    // One spawn event: one axis, shared by every enemy in the wave.
    const axis = surgeAxis(&r, tick).?;
    try std.testing.expect(axis >= 0.0 and axis < 2.0 * pi);

    // The two arms are pi apart, so folding every angle onto [0, pi) collapses
    // them into a single cluster, and the axis is inside that cluster: the
    // cluster's width is therefore at most the 30 degree arc's.
    const centre = @mod(axis, pi);
    var max_dev: f32 = 0.0;
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const a = spawnAngle(&r, axis);
        try std.testing.expect(a >= 0.0 and a < 2.0 * pi);
        var d = @abs(@mod(a, pi) - centre);
        d = @min(d, pi - d); // circular distance on the folded half-circle
        max_dev = @max(max_dev, d);
    }
    try std.testing.expect(max_dev <= 2.0 * surge_arc_rad + 1e-3);
    // ... and both arms are actually used.
    var arms: [2]bool = @splat(false);
    i = 0;
    while (i < 500) : (i += 1) {
        const a = spawnAngle(&r, axis);
        var delta = @mod(a - axis, 2.0 * pi);
        arms[if (delta < pi) 0 else 1] = true;
        _ = &delta;
    }
    try std.testing.expect(arms[0] and arms[1]);

    // With no surge axis the angle is uniform over the whole circle.
    try std.testing.expect(surgeAxis(&r, 10) == null);
    var lo: f32 = std.math.inf(f32);
    var hi: f32 = -std.math.inf(f32);
    i = 0;
    while (i < 500) : (i += 1) {
        const a = spawnAngle(&r, null);
        lo = @min(lo, a);
        hi = @max(hi, a);
    }
    try std.testing.expect(lo < 0.3 and hi > 5.9);
}

test "spawn fills the pool and refuses to overrun it" {
    var pool = Pool{};
    var i: usize = 0;
    while (i < root.max_enemies) : (i += 1) {
        const slot = pool.spawn(.circle_t1, .{ 1.0, 2.0 }) orelse return error.SpawnRefusedEarly;
        try std.testing.expectEqual(i, slot);
    }
    try std.testing.expect(pool.spawn(.circle_t1, .{ 0.0, 0.0 }) == null);
    try std.testing.expectEqual(root.max_enemies, pool.count);

    // An archetype this phase does not implement is refused outright.
    var small = Pool{};
    try std.testing.expect(small.spawn(.circle_t2, .{ 0.0, 0.0 }) == null);
    try std.testing.expectEqual(@as(usize, 0), small.count);
}

test "spawn gives every enemy a distinct id and the archetype's stats" {
    var pool = Pool{};
    const a = pool.spawn(.circle_t1, .{ 5.0, -5.0 }).?;
    const b = pool.spawn(.triangle_t1, .{ 6.0, -6.0 }).?;

    try std.testing.expect(pool.id[a] != pool.id[b]);
    try std.testing.expectEqual(@as(u32, 1), pool.id[a]);
    try std.testing.expectEqual(@as(u32, 2), pool.id[b]);
    try std.testing.expectEqual(@intFromEnum(Archetype.circle_t1), pool.archetype[a]);
    try std.testing.expectEqual(@intFromEnum(Archetype.triangle_t1), pool.archetype[b]);
    try std.testing.expectEqual(@as(f32, 15.0), pool.hp[a]);
    try std.testing.expectEqual(@as(f32, 10.0), pool.max_hp[b]);
    try std.testing.expectEqual(@as(f32, 7.0), pool.move_speed[b]);
    try std.testing.expectEqual(@as(f32, 8.0), pool.contact_dmg[b]);
    try std.testing.expectEqual([2]f32{ 5.0, -5.0 }, pool.pos[a]);
    try std.testing.expectEqual(@as(u8, 0), pool.elite_mask[a]);
    try std.testing.expectEqual(@as(u8, @intFromEnum(AiState.pursue)), pool.ai_state[a]);
}

test "swapRemove keeps the pool dense and carries every field across" {
    var pool = Pool{};
    const a = pool.spawn(.circle_t1, .{ 1.0, 1.0 }).?;
    const b = pool.spawn(.triangle_t1, .{ 2.0, 2.0 }).?;
    const c = pool.spawn(.circle_t1, .{ 3.0, 3.0 }).?;
    pool.hp[b] = 4.0;
    pool.kb[b] = .{ 9.0, 8.0 };
    pool.ai_state[b] = @intFromEnum(AiState.lunge);
    pool.ai_timer[b] = 17;
    const moved_id = pool.id[c];
    const moved_pos = pool.pos[c];

    pool.swapRemove(a);

    try std.testing.expectEqual(@as(usize, 2), pool.count);
    // The last enemy now occupies slot `a` with every field intact.
    try std.testing.expectEqual(moved_id, pool.id[a]);
    try std.testing.expectEqual(moved_pos, pool.pos[a]);
    try std.testing.expectEqual(@as(f32, 15.0), pool.hp[a]);
    // Slot `b` is untouched.
    try std.testing.expectEqual(@as(f32, 4.0), pool.hp[b]);
    try std.testing.expectEqual([2]f32{ 9.0, 8.0 }, pool.kb[b]);
    try std.testing.expectEqual(@as(u16, 17), pool.ai_timer[b]);
    try std.testing.expectEqual(@as(u8, @intFromEnum(AiState.lunge)), pool.ai_state[b]);

    // Removing the tail slot needs no move.
    pool.swapRemove(pool.count - 1);
    try std.testing.expectEqual(@as(usize, 1), pool.count);
}

test "reapDead compacts the pool and counts kills" {
    var pool = Pool{};
    _ = pool.spawn(.circle_t1, .{ 0.0, 0.0 });
    const b = pool.spawn(.circle_t1, .{ 1.0, 0.0 }).?;
    _ = pool.spawn(.circle_t1, .{ 2.0, 0.0 });
    const d = pool.spawn(.circle_t1, .{ 3.0, 0.0 }).?;
    pool.hp[b] = 0.0;
    pool.hp[d] = -3.0;

    try std.testing.expectEqual(@as(usize, 2), pool.reapDead());
    try std.testing.expectEqual(@as(usize, 2), pool.count);
    for (0..pool.count) |i| try std.testing.expect(pool.hp[i] > 0.0);
    try std.testing.expectEqual(@as(usize, 0), pool.reapDead());
}

test "applyHit subtracts damage, adds knockback and reports the kill" {
    var pool = Pool{};
    const i = pool.spawn(.circle_t1, .{ 0.0, 0.0 }).?;

    try std.testing.expect(!pool.applyHit(i, 10.0, .{ 1.0, 0.0 }, 3.0));
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), pool.hp[i], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), pool.kb[i][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), pool.kb[i][1], 1e-6);

    try std.testing.expect(pool.applyHit(i, 5.0, .{ 0.0, -1.0 }, 2.0));
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), pool.hp[i], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -2.0), pool.kb[i][1], 1e-6);
}
