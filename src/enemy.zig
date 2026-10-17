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
/// The boss is the widest body in the game at 3.0 units.
pub const max_radius: f32 = 3.0;

/// Per-archetype stats (DESIGN.md §4).
pub const Stats = struct {
    hp: f32,
    move_speed: f32,
    contact_dmg: f32,
    radius: f32,
    /// Simulation tick at which the archetype unlocks (DESIGN.md §4 "Tier &
    /// unlock"). Circle T1 is available from the first tick; the boss is not
    /// on the spawn curve at all and is placed by its own 180 s timer.
    unlock_tick: u32,
    /// Fraction of a knockback impulse that survives (DESIGN.md §4: the Brute
    /// resists 50%, the Goliath 85%, the boss and a charging Lancer 100%).
    knockback_resist: f32 = 0.0,
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
        .circle_t2 => .{
            .hp = 80.0,
            .move_speed = 3.8,
            .contact_dmg = 12.0,
            .radius = 0.9,
            .unlock_tick = 5 * 60 * root.tick_hz, // 5:00
            .knockback_resist = 0.5,
        },
        .triangle_t2 => .{
            .hp = 45.0,
            .move_speed = 5.0,
            .contact_dmg = 10.0,
            .radius = 0.7,
            .unlock_tick = 7 * 60 * root.tick_hz, // 7:00
        },
        .circle_t3 => .{
            .hp = 320.0,
            .move_speed = 3.2,
            .contact_dmg = 22.0,
            .radius = 1.4,
            .unlock_tick = 12 * 60 * root.tick_hz, // 12:00
            .knockback_resist = 0.85,
        },
        .triangle_t3 => .{
            .hp = 180.0,
            .move_speed = 8.5,
            .contact_dmg = 28.0,
            .radius = 1.0,
            .unlock_tick = 14 * 60 * root.tick_hz, // 14:00
        },
        .boss => .{
            .hp = 2500.0,
            .move_speed = 5.5,
            .contact_dmg = 35.0,
            .radius = 3.0,
            .unlock_tick = 0,
            .knockback_resist = 1.0,
        },
    };
}

/// Archetypes this phase can spawn.
pub const implemented = [_]Archetype{
    .circle_t1, .circle_t2, .circle_t3,
    .triangle_t1, .triangle_t2, .triangle_t3,
    .boss,
};

// ---------------------------------------------------------------------------
// Difficulty curve (DESIGN.md §1)
// ---------------------------------------------------------------------------

/// `M_HP(t)`, the enemy health multiplier, as a function of elapsed minutes.
///
/// The four phases of DESIGN.md §1, stitched continuously: linear onboarding
/// to 5:00, quadratic mid-game to 15:00, exponential climax to 20:00, and
/// endless escalation past it. Applied to an enemy's health when it spawns.
pub fn hpMultiplier(t_minutes: f32) f32 {
    if (t_minutes <= 5.0) return 1.0 + 0.20 * t_minutes;
    if (t_minutes <= 15.0) return 2.0 + 0.25 * (t_minutes - 5.0) * (t_minutes - 5.0);
    if (t_minutes <= 20.0) return 27.0 * std.math.pow(f32, 1.22, t_minutes - 15.0);
    return 73.0 * std.math.pow(f32, 1.35, t_minutes - 20.0);
}

/// Enemy move-speed multiplier: +4% per minute past 20:00 (DESIGN.md §1,
/// Phase D). Below 20:00 the curve does not touch speed.
pub fn speedMultiplier(t_minutes: f32) f32 {
    if (t_minutes <= 20.0) return 1.0;
    return 1.0 + 0.04 * (t_minutes - 20.0);
}

// ---------------------------------------------------------------------------
// Elite modifiers (DESIGN.md §4)
// ---------------------------------------------------------------------------

/// `elite_mask` bit layout. An elite carries exactly one modifier; the field
/// is a mask so the client reads each bit independently and a later phase can
/// combine them.
pub const elite = struct {
    pub const vampiric: u8 = 1 << 0;
    pub const splitter: u8 = 1 << 1;
    pub const shielded: u8 = 1 << 2;
    pub const haste_aura: u8 = 1 << 3;

    /// Elites gain 3.0x HP and +25% radius, and drop 5x XP (DESIGN.md §4).
    pub const hp_mult: f32 = 3.0;
    pub const radius_mult: f32 = 1.25;

    /// Vampiric: +20% move speed, and restores 15% max HP on damaging a player.
    pub const vampiric_speed_mult: f32 = 1.20;
    pub const vampiric_heal: f32 = 0.15;

    /// Haste Aura: an 8.0 u aura granting +35% movement speed to nearby enemies.
    pub const haste_radius: f32 = 8.0;
    pub const haste_speed_mult: f32 = 1.35;

    /// Shielded: a barrier of 50% max HP that regenerates after 3.0 s without
    /// taking damage.
    pub const shield_barrier: f32 = 0.5;
    pub const shield_regen_ticks: u16 = 3 * root.tick_hz;

    /// Splitter: on death, splits into 3 miniature copies with 30% HP, +30%
    /// speed and 0.6x radius.
    pub const splitter_copies: usize = 3;
    pub const splitter_hp: f32 = 0.30;
    pub const splitter_speed: f32 = 1.30;
    pub const splitter_radius: f32 = 0.60;
};

/// Elite spawn chance `1% + 0.5% x t`, capped at 15% (DESIGN.md §4).
pub fn eliteChance(t_minutes: f32) f32 {
    return @min(0.01 + 0.005 * t_minutes, 0.15);
}

// ---------------------------------------------------------------------------
// Boss (DESIGN.md §4)
// ---------------------------------------------------------------------------

pub const boss = struct {
    /// One boss every 180 s (3:00, 6:00, 9:00, ...).
    pub const interval_ticks: u32 = 180 * root.tick_hz;
    /// `2500 x M_HP(t) x (1 + 0.75(P - 1))`; the party term is applied by the
    /// spawner, which knows the player count.
    pub const base_hp: f32 = 2500.0;
    pub const party_hp_step: f32 = 0.75;

    /// Attack cycle: a 6.0 s loop alternating a 12-projectile radial burst
    /// with a telegraphed dash. Attacks land every 3.0 s, alternating.
    pub const attack_interval_ticks: u32 = 3 * root.tick_hz;
    pub const burst_count: usize = 12;
    pub const burst_speed: f32 = 14.0;
    pub const burst_damage: f32 = 18.0;
    pub const burst_ttl_ticks: u16 = 2 * root.tick_hz;
    /// The dash is telegraphed by a 1.0 s warning box, then runs for 1.0 s at
    /// 22.0 u/s (22 units). DESIGN.md fixes the warning and the speed but not
    /// the dash length; 1.0 s is the reading here.
    pub const dash_speed: f32 = 22.0;
    pub const telegraph_ticks: u32 = root.tick_hz;
    pub const dash_ticks: u32 = root.tick_hz;
};

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

/// Spitter behaviour constants (DESIGN.md §4, Triangle T2).
pub const spitter = struct {
    /// Range at which the spitter halts and starts firing.
    pub const fire_range: f32 = 18.0;
    /// Seconds between shots.
    pub const fire_interval_ticks: u16 = 150; // 2.5 s
    /// Projectile speed and damage.
    pub const shot_speed: f32 = 9.0;
    pub const shot_damage: f32 = 10.0;
    pub const shot_ttl_ticks: u16 = 150; // 2.5 s of travel
    /// How far outside `fire_range` the player must move before the spitter
    /// resumes pursuit, so one sitting on the boundary does not oscillate.
    pub const resume_band: f32 = 4.0;
};

/// Lancer behaviour constants (DESIGN.md §4, Triangle T3).
pub const lancer = struct {
    /// Seconds between charge-vector locks.
    pub const lock_interval_ticks: u16 = 240; // 4.0 s
    /// Charge speed and the distance it covers (24.0 u at 20.0 u/s = 1.2 s).
    pub const charge_speed: f32 = 20.0;
    pub const charge_distance: f32 = 24.0;
    pub const charge_ticks: u16 = 72; // 1.2 s
};

/// Enemy AI states.
///
/// The darter leaves `pursue` for `windup`/`lunge`; the lancer for `charge`;
/// the spitter for `halt`; the boss for `telegraph`/`lunge`.
pub const AiState = enum(u8) {
    pursue = 0,
    windup = 1,
    lunge = 2,
    halt = 3,
    charge = 4,
    telegraph = 5,
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
///
/// DESIGN.md §1 describes Phase A as *"spawn density scales linearly 3.0 → 14.0
/// enemies/sec"*, which is this formula's linear term alone: `3.0 + 2.2t` reads
/// 14.0 at 5:00, while the full formula reads 22.75. The two readings cannot
/// both hold. The formula wins: §4 is the section that defines the spawner
/// ("Spawn formula over time", evaluated every 60 ticks) and §1 is the narrative
/// pacing summary, whose own endpoint is exactly the linear term's. The
/// quadratic term is also what makes §4's later phases escalate at all.
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
/// DESIGN.md §4 gives unlock times but no mix ratio, so every unlocked
/// archetype is in play and the draw is weighted toward the higher tiers
/// (Tier 1 = 1, Tier 2 = 2, Tier 3 = 3): the mix escalates as the run
/// progresses, which is the curve the design is after. The boss is not on the
/// curve — it is placed by its own 180 s timer.
pub fn pickArchetype(r: *rng.Rng, tick: u32) Archetype {
    const table = [_]struct { a: Archetype, weight: usize }{
        .{ .a = .circle_t1, .weight = 1 },
        .{ .a = .triangle_t1, .weight = 1 },
        .{ .a = .circle_t2, .weight = 2 },
        .{ .a = .triangle_t2, .weight = 2 },
        .{ .a = .circle_t3, .weight = 3 },
        .{ .a = .triangle_t3, .weight = 3 },
    };

    var total: usize = 0;
    for (table) |entry| {
        if (tick >= stats(entry.a).?.unlock_tick) total += entry.weight;
    }
    // Circle T1 is always unlocked, so the total is never zero.
    var pick = r.below(total);
    for (table) |entry| {
        if (tick < stats(entry.a).?.unlock_tick) continue;
        if (pick < entry.weight) return entry.a;
        pick -= entry.weight;
    }
    return .circle_t1;
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
    /// Vulcan Minigun: multiplier on damage taken (1.0 = no debuff).
    debuff_mult: [root.max_enemies]f32 = @splat(1.0),
    /// Cryo Flechette: ticks of slow left, and the speed factor while slowed.
    slow_ticks: [root.max_enemies]u16 = @splat(0),
    slow_factor: [root.max_enemies]f32 = @splat(1.0),
    /// Cryo Flechette: slow stacks, and ticks of freeze once the stacks land.
    cryo_stacks: [root.max_enemies]u8 = @splat(0),
    freeze_ticks: [root.max_enemies]u16 = @splat(0),
    /// Target Painter: ticks of mark left by a Gun hit (DESIGN.md §3).
    marked_ticks: [root.max_enemies]u16 = @splat(0),
    /// Fraction of a knockback impulse that survives (DESIGN.md §4).
    kb_resist: [root.max_enemies]f32 = @splat(0.0),
    /// Direction this enemy faces, which is what the wire's `vel_angle`
    /// reports. Equal to the movement direction, except for a boss telegraphing
    /// a dash: it stands still but faces the way it is about to go.
    facing: [root.max_enemies][2]f32 = @splat(.{ 1.0, 0.0 }),
    /// Boss only: immune to Cryo Flechette's freeze (DESIGN.md §4).
    status_immune: [root.max_enemies]bool = @splat(false),
    /// Shielded elite: a barrier absorbed ahead of HP (DESIGN.md §4).
    barrier: [root.max_enemies]f32 = @splat(0.0),
    /// Shielded elite: ticks of no damage left before the barrier regenerates.
    shielded_regen: [root.max_enemies]u16 = @splat(0),
    /// Boss: which attack comes next (0 = radial burst, 1 = telegraphed dash).
    boss_parity: [root.max_enemies]u8 = @splat(0),
    /// Enemies that died while frozen, queued for Cryo Flechette's shatter
    /// (DESIGN.md §3). `sim.zig` drains this after `reapDead`.
    shatter_pos: [root.max_enemies][2]f32 = @splat(.{ 0.0, 0.0 }),
    shatter_radius: [root.max_enemies]f32 = @splat(0.0),
    shatter_damage: [root.max_enemies]f32 = @splat(0.0),
    shatter_count: usize = 0,

    /// Spawn-time overrides. The difficulty curve, the elite modifiers and the
    /// Splitter's minis all scale an archetype's base stats, and the boss's HP
    /// formula replaces them outright, so a spawn is parameterised rather than
    /// hardcoded to the archetype's row.
    pub const SpawnOpts = struct {
        /// Absolute HP; `null` takes the archetype's base, scaled by `hp_mult`.
        hp: ?f32 = null,
        hp_mult: f32 = 1.0,
        /// Absolute radius / speed; `null` takes the archetype's base scaled by
        /// the corresponding `_mult`.
        radius: ?f32 = null,
        radius_mult: f32 = 1.0,
        speed: ?f32 = null,
        speed_mult: f32 = 1.0,
        elite_mask: u8 = 0,
        knockback_resist: f32 = 0.0,
        status_immune: bool = false,
    };

    /// Spawn with scaled stats. `null` is the archetype's own row.
    pub fn spawnWith(
        self: *Pool,
        archetype: Archetype,
        pos: [2]f32,
        opts: SpawnOpts,
    ) ?usize {
        if (self.count >= root.max_enemies) return null;
        const s = stats(archetype) orelse return null;

        const i = self.count;
        self.id[i] = self.next_id;
        self.next_id +%= 1;
        self.archetype[i] = @intFromEnum(archetype);
        self.elite_mask[i] = opts.elite_mask;
        self.ai_state[i] = @intFromEnum(AiState.pursue);
        self.ai_timer[i] = 0;
        self.contact_cd[i] = 0;
        self.pos[i] = pos;
        self.vel[i] = .{ 0.0, 0.0 };
        self.kb[i] = .{ 0.0, 0.0 };
        self.hp[i] = (opts.hp orelse s.hp) * opts.hp_mult;
        self.max_hp[i] = (opts.hp orelse s.hp) * opts.hp_mult;
        self.radius[i] = (opts.radius orelse s.radius) * opts.radius_mult;
        self.contact_dmg[i] = s.contact_dmg;
        self.move_speed[i] = (opts.speed orelse s.move_speed) * opts.speed_mult;
        self.kb_resist[i] = opts.knockback_resist;
        self.facing[i] = .{ 1.0, 0.0 };
        self.status_immune[i] = opts.status_immune;
        self.barrier[i] = 0.0;
        self.shielded_regen[i] = 0;
        self.boss_parity[i] = 0;
        self.debuff_mult[i] = 1.0;
        self.slow_ticks[i] = 0;
        self.slow_factor[i] = 1.0;
        self.cryo_stacks[i] = 0;
        self.freeze_ticks[i] = 0;
        self.count += 1;
        return i;
    }

    /// Reserve a slot with the archetype's base stats. Returns `null` when the
    /// pool is full or the archetype is not implemented — a full pool must
    /// degrade, not crash.
    pub fn spawn(self: *Pool, archetype: Archetype, pos: [2]f32) ?usize {
        return self.spawnWith(archetype, pos, .{});
    }

    /// True when slot `i` holds the boss.
    pub fn isBoss(self: *const Pool, i: usize) bool {
        return self.archetype[i] == @intFromEnum(Archetype.boss);
    }

    /// How many bosses are live. The spawner places at most one at a time.
    pub fn bossCount(self: *const Pool) usize {
        var n: usize = 0;
        for (0..self.count) |i| {
            if (self.isBoss(i)) n += 1;
        }
        return n;
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
                    !std.mem.eql(u8, name, "next_id") and
                    !std.mem.eql(u8, name, "shatter_count") and
                    // The shatter queue is indexed by its own count, not by
                    // the entity slot, so it must not follow a swap.
                    !std.mem.eql(u8, name, "shatter_pos") and
                    !std.mem.eql(u8, name, "shatter_radius") and
                    !std.mem.eql(u8, name, "shatter_damage"))
                {
                    @field(self, name)[i] = @field(self, name)[last];
                }
            }
        }
        self.count -= 1;
    }

    /// Compact away every enemy at or below zero HP. Returns the kill count.
    ///
    /// An enemy that dies while frozen is queued for Cryo Flechette's shatter
    /// (DESIGN.md §3); `sim.zig` drains `shatter_*` after this returns. A
    /// Splitter elite splits into its miniature copies on death (DESIGN.md §4):
    /// the copies are appended to the pool, alive, so they are not reaped by
    /// this same pass.
    pub fn reapDead(self: *Pool) usize {
        var killed: usize = 0;
        var i: usize = 0;
        while (i < self.count) {
            if (self.hp[i] <= 0.0) {
                if (self.freeze_ticks[i] > 0 and self.shatter_count < root.max_enemies) {
                    const k = self.shatter_count;
                    self.shatter_pos[k] = self.pos[i];
                    self.shatter_radius[k] = 3.0;
                    self.shatter_damage[k] = 120.0;
                    self.shatter_count += 1;
                }
                if (self.elite_mask[i] & elite.splitter != 0) {
                    self.splitIntoMinis(i);
                }
                self.swapRemove(i);
                killed += 1;
            } else {
                i += 1;
            }
        }
        return killed;
    }

    /// Spawn a Splitter's three miniature copies where it died (DESIGN.md §4):
    /// 30% of the parent's max HP, +30% speed, 0.6x radius, no elite mask, so
    /// the copies cannot split again.
    fn splitIntoMinis(self: *Pool, i: usize) void {
        const a: Archetype = @enumFromInt(self.archetype[i]);
        var k: usize = 0;
        while (k < elite.splitter_copies) : (k += 1) {
            const angle = @as(f32, @floatFromInt(k)) * (2.0 * std.math.pi / @as(f32, @floatFromInt(elite.splitter_copies)));
            const pos = .{
                self.pos[i][0] + @cos(angle) * self.radius[i],
                self.pos[i][1] + @sin(angle) * self.radius[i],
            };
            _ = self.spawnWith(a, pos, .{
                .hp = elite.splitter_hp * self.max_hp[i],
                .radius = elite.splitter_radius * self.radius[i],
                .speed = elite.splitter_speed * self.move_speed[i],
            });
        }
    }

    /// Apply `amount` damage and `impulse` knockback along `dir`. Returns true
    /// when this hit killed the enemy.
    ///
    /// The Vulcan Minigun's stacking debuff multiplies the damage taken, so a
    /// debuffed enemy takes more than the raw amount. A Shielded elite's barrier
    /// absorbs ahead of HP, and the archetype's knockback resistance scales the
    /// impulse.
    pub fn applyHit(self: *Pool, i: usize, amount: f32, dir: [2]f32, impulse: f32) bool {
        var damage = amount * self.debuff_mult[i];
        if (self.barrier[i] > 0.0) {
            const absorbed = @min(self.barrier[i], damage);
            self.barrier[i] -= absorbed;
            damage -= absorbed;
            // Taking damage restarts the barrier's regeneration delay.
            self.shielded_regen[i] = elite.shield_regen_ticks;
        }
        self.hp[i] -= damage;
        const scale = 1.0 - self.kb_resist[i];
        self.kb[i][0] += dir[0] * impulse * scale;
        self.kb[i][1] += dir[1] * impulse * scale;
        return self.hp[i] <= 0.0;
    }

    /// Age every Shielded barrier's regeneration delay and restore the barrier
    /// to its full 50% once the enemy has gone 3.0 s without taking damage.
    pub fn tickShieldRegen(self: *Pool) void {
        for (0..self.count) |i| {
            if (self.elite_mask[i] & elite.shielded == 0) continue;
            if (self.barrier[i] >= elite.shield_barrier * self.max_hp[i]) continue;
            if (self.shielded_regen[i] > 0) {
                self.shielded_regen[i] -= 1;
                if (self.shielded_regen[i] == 0) {
                    self.barrier[i] = elite.shield_barrier * self.max_hp[i];
                }
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "archetype stats match DESIGN.md §4" {
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

    const brute = stats(.circle_t2).?;
    try std.testing.expectEqual(@as(f32, 80.0), brute.hp);
    try std.testing.expectEqual(@as(f32, 3.8), brute.move_speed);
    try std.testing.expectEqual(@as(f32, 12.0), brute.contact_dmg);
    try std.testing.expectEqual(@as(f32, 0.9), brute.radius);
    try std.testing.expectEqual(@as(u32, 5 * 60 * 60), brute.unlock_tick);
    try std.testing.expectEqual(@as(f32, 0.5), brute.knockback_resist);

    const spitter_stats = stats(.triangle_t2).?;
    try std.testing.expectEqual(@as(f32, 45.0), spitter_stats.hp);
    try std.testing.expectEqual(@as(f32, 5.0), spitter_stats.move_speed);
    try std.testing.expectEqual(@as(f32, 10.0), spitter_stats.contact_dmg);
    try std.testing.expectEqual(@as(f32, 0.7), spitter_stats.radius);
    try std.testing.expectEqual(@as(u32, 7 * 60 * 60), spitter_stats.unlock_tick);

    const goliath = stats(.circle_t3).?;
    try std.testing.expectEqual(@as(f32, 320.0), goliath.hp);
    try std.testing.expectEqual(@as(f32, 3.2), goliath.move_speed);
    try std.testing.expectEqual(@as(f32, 22.0), goliath.contact_dmg);
    try std.testing.expectEqual(@as(f32, 1.4), goliath.radius);
    try std.testing.expectEqual(@as(u32, 12 * 60 * 60), goliath.unlock_tick);
    try std.testing.expectEqual(@as(f32, 0.85), goliath.knockback_resist);

    const lancer_stats = stats(.triangle_t3).?;
    try std.testing.expectEqual(@as(f32, 180.0), lancer_stats.hp);
    try std.testing.expectEqual(@as(f32, 8.5), lancer_stats.move_speed);
    try std.testing.expectEqual(@as(f32, 28.0), lancer_stats.contact_dmg);
    try std.testing.expectEqual(@as(f32, 1.0), lancer_stats.radius);
    try std.testing.expectEqual(@as(u32, 14 * 60 * 60), lancer_stats.unlock_tick);

    const boss_stats = stats(.boss).?;
    try std.testing.expectEqual(@as(f32, 2500.0), boss_stats.hp);
    try std.testing.expectEqual(@as(f32, 5.5), boss_stats.move_speed);
    try std.testing.expectEqual(@as(f32, 35.0), boss_stats.contact_dmg);
    try std.testing.expectEqual(@as(f32, 3.0), boss_stats.radius);
    try std.testing.expectEqual(@as(f32, 1.0), boss_stats.knockback_resist);

    // The boss is the widest body in the game.
    try std.testing.expectEqual(@as(f32, 3.0), max_radius);
}

test "the difficulty curve follows DESIGN.md §1" {
    // Phase A: 1.0 + 0.20t.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), hpMultiplier(0.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), hpMultiplier(5.0), 1e-6);
    // Phase B: 2.0 + 0.25(t-5)^2, continuous with A at 5:00.
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), hpMultiplier(5.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 4.25), hpMultiplier(8.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 27.0), hpMultiplier(15.0), 1e-6);
    // Phase C: 27.0 x 1.22^(t-15), continuous with B at 15:00.
    try std.testing.expectApproxEqAbs(@as(f32, 27.0), hpMultiplier(15.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 73.0), hpMultiplier(20.0), 0.05);
    // Phase D: 73.0 x 1.35^(t-20), continuous with C at 20:00.
    try std.testing.expectApproxEqAbs(@as(f32, 73.0), hpMultiplier(20.0), 0.05);
    try std.testing.expect(hpMultiplier(25.0) > hpMultiplier(20.0));

    // Speed: +4% per minute past 20:00, untouched below it.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), speedMultiplier(0.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), speedMultiplier(20.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.04), speedMultiplier(21.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.20), speedMultiplier(25.0), 1e-6);
}

test "the elite spawn chance follows DESIGN.md §4" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.01), eliteChance(0.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), eliteChance(8.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.11), eliteChance(20.0), 1e-6);
    // Capped at 15%, which the raw formula reaches at 28:00.
    try std.testing.expectApproxEqAbs(@as(f32, 0.15), eliteChance(28.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.15), eliteChance(100.0), 1e-6);
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

test "the 5:00 spawn rate is the formula's 22.75, not §1's linear 14.0" {
    // 3.0 + 2.2 x 5 + 0.35 x 25 = 22.75.
    try std.testing.expectApproxEqAbs(@as(f32, 22.75), spawnRate(5.0, 1), 1e-4);
    // §1's endpoint is the linear term's, which the formula only reaches if the
    // quadratic term is dropped. Pinned here so the reading is a decision the
    // code states rather than an accident of arithmetic.
    try std.testing.expectApproxEqAbs(@as(f32, 14.0), 3.0 + 2.2 * 5.0, 1e-5);
    try std.testing.expect(spawnRate(5.0, 1) > 14.0);
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

    // A full pool refuses a boss too, rather than overrunning.
    try std.testing.expect(pool.spawn(.boss, .{ 0.0, 0.0 }) == null);
}

test "spawnWith scales an archetype's stats and carries the elite mask" {
    var pool = Pool{};
    const base = pool.spawn(.circle_t1, .{ 1.0, 1.0 }).?;
    try std.testing.expectEqual(@as(f32, 15.0), pool.hp[base]);
    try std.testing.expectEqual(@as(f32, 0.5), pool.radius[base]);
    try std.testing.expectEqual(@as(f32, 4.5), pool.move_speed[base]);
    try std.testing.expectEqual(@as(u8, 0), pool.elite_mask[base]);

    // An elite brute: 3.0x HP, +25% radius, Vampiric's +20% speed.
    const elite_i = pool.spawnWith(.circle_t2, .{ 2.0, 2.0 }, .{
        .hp_mult = 3.0,
        .radius_mult = 1.25,
        .speed_mult = 1.2,
        .elite_mask = elite.vampiric,
    }).?;
    try std.testing.expectEqual(@as(f32, 80.0 * 3.0), pool.hp[elite_i]);
    try std.testing.expectEqual(@as(f32, 0.9 * 1.25), pool.radius[elite_i]);
    try std.testing.expectEqual(@as(f32, 3.8 * 1.2), pool.move_speed[elite_i]);
    try std.testing.expectEqual(elite.vampiric, pool.elite_mask[elite_i]);

    // The boss's HP formula replaces the base outright.
    const boss_i = pool.spawnWith(.boss, .{ 3.0, 3.0 }, .{
        .hp_mult = 73.0 * 1.75,
        .knockback_resist = 1.0,
        .status_immune = true,
    }).?;
    try std.testing.expectEqual(@as(f32, 2500.0 * 73.0 * 1.75), pool.hp[boss_i]);
    try std.testing.expectEqual(@as(f32, 2500.0 * 73.0 * 1.75), pool.max_hp[boss_i]);
    try std.testing.expectEqual(@as(f32, 3.0), pool.radius[boss_i]);
    try std.testing.expectEqual(@as(f32, 1.0), pool.kb_resist[boss_i]);
    try std.testing.expect(pool.status_immune[boss_i]);
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
