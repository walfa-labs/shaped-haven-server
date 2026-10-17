//! Shaped Haven server — deterministic simulation core.
//!
//! This module is deliberately free of I/O: it owns the world state and
//! advances it one fixed 60 Hz step at a time. Networking lives in `server.zig`,
//! which feeds inputs in and reads snapshots out.
//!
//! Phase 3 adds the upgrade engine on top of the phase-2 combat core: XP gems
//! and the magnet, the XP curve and the level-up pause, the ten passives, the
//! eight-level weapon tables, the eight evolutions, the five synergies, the
//! uncapped Overclock endgame, and player death.
//!
//! The order of systems inside a tick is fixed, because determinism depends on
//! it:
//!
//! 1. players integrate their input, and regen/timers tick;
//! 2. enemies run their AI (slowed or frozen), integrate, and are clamped;
//! 3. the broadphase grid is rebuilt from the enemies' new positions;
//! 4. every ready weapon fires — resolved through the loadout, with the
//!    evolution and synergy effects;
//! 5. projectiles travel and resolve what they overlap;
//! 6. enemies touching a player deal contact damage, reduced by armor and
//!    absorbed by shield;
//! 7. dead enemies drop a gem; dead enemies and spent projectiles are compacted;
//! 8. gems magnetize, fly, and are collected, awarding XP;
//! 9. ground rifts damage what stands in them and expire;
//! 10. a filled XP bar pauses the run and offers three choices;
//! 11. once per second the spawn formula is evaluated.
//!
//! Nothing moves between step 3 and step 7 except knockback *velocity*, which
//! only changes where an enemy will be next tick — so every grid query in a
//! tick sees a consistent set of indices, and the pools can be compacted once,
//! at the end.

const std = @import("std");
const root = @import("root.zig");
const wire = @import("wire.zig");
const enemy = @import("enemy.zig");
const weapon = @import("weapon.zig");
const combat = @import("combat.zig");
const spatial = @import("spatial.zig");
const rng = @import("rng.zig");
const upgrade = @import("upgrade.zig");
const loadout = @import("loadout.zig");
const gem = @import("gem.zig");
const evolve = @import("evolve.zig");

/// Simulation state (DESIGN.md §5 game_state values).
pub const GameState = enum(u8) {
    running = 0,
    level_up_pause = 1,
    game_over = 2,
};

/// `C2S_INPUT` mapped onto a player slot.
pub const InputFrame = struct {
    input_seq: u32 = 0,
    client_tick: u32 = 0,
    move_x: i8 = 0,
    move_y: i8 = 0,
    aim_angle: u16 = 0,
    buttons: u8 = 0,
};

/// DESIGN.md §2 `state_flags` bit layout.
pub const Flag = enum(u8) {
    alive = 1,
    invulnerable = 2,
    awaiting_levelup = 4,
};

pub const StateFlags = struct {
    alive: bool = true,
    invulnerable: bool = false,
    awaiting_levelup: bool = false,

    pub fn byte(f: StateFlags) u8 {
        return @as(u8, @intFromBool(f.alive)) |
            @as(u8, @intFromBool(f.invulnerable)) << 1 |
            @as(u8, @intFromBool(f.awaiting_levelup)) << 2;
    }
};

pub const WeaponSlot = upgrade.WeaponSlot;

/// Range at which a weapon will acquire a target, in world units.
///
/// DESIGN.md §3 gives each weapon a reach but never says what a player shoots
/// at, and this phase has no aiming input: every weapon auto-fires at the
/// nearest enemy. The acquisition range is the viewport's half-diagonal
/// (40 x 22.5 units, DESIGN.md §1), so a weapon engages anything on screen.
/// Whether a given weapon can actually *reach* that target is its own business:
/// the sword swings and hits nothing if the nearest enemy is 20 units away,
/// exactly as it would in the genre this game is modelled on.
pub const acquire_range: f32 = 45.0;

/// Ticks the level-up offer waits before auto-selecting option 0
/// (DESIGN.md §5: a 15.0 s server timeout).
pub const levelup_timeout_ticks: u32 = 15 * root.tick_hz;

/// Speed a magnetized gem flies at, in units per second.
pub const gem_magnet_speed: f32 = 18.0;

/// Distance at which a magnetized gem is collected.
pub const gem_collect_radius: f32 = 0.6;

/// Fixed seed for the spawn RNG, so a run is reproducible. A phase that wants
/// per-run variety changes this at `Simulation.init`, not here.
pub const spawn_seed: u64 = 0x5eed5eed5eed5eed;

/// Seed for the level-up choice generator. Separate from the spawn RNG so a
/// draft never perturbs the spawn curve.
pub const upgrade_seed: u64 = 0x0ddba110ddba1100;

/// A fixed load to hold for the whole run, instead of the natural spawn curve.
///
/// This exists so the phase-2 definition of done can be *observed* rather than
/// waited for: the natural curve of DESIGN.md §4 does not reach 1,000 live
/// enemies until roughly twelve minutes in, which is far too long to sit
/// through while measuring a frame rate. It is a measurement tool, off in
/// normal play, and the server only turns it on from `--stress-enemies`.
pub const StressLoad = struct {
    enemies: usize,
    projectiles: usize,
    /// Radius of the disc the load is placed in, around the players' centroid.
    radius: f32 = 35.0,
};

/// One pending level-up offer, waiting for `C2S_LEVELUP_CHOICE`.
///
/// The simulation pauses while any of these is unresolved; the server drains
/// the ones with `sent == false` and sends each an `S2C_LEVELUP_OFFER`.
pub const LevelUp = struct {
    event_id: u16,
    player_id: u8,
    new_level: u16,
    options: [3]upgrade.UpgradeOption,
    timeout_ticks: u32,
    resolved: bool,
    sent: bool,
};

/// One player in the simulation (DESIGN.md §2 field list).
pub const PlayerState = struct {
    id: u8 = 0,
    active: bool = false,
    flags: StateFlags = .{},
    pos: [2]f32 = .{ 0.0, 0.0 },
    vel: [2]f32 = .{ 0.0, 0.0 },
    aim_dir: [2]f32 = .{ 1.0, 0.0 },
    hp: f32 = root.player_max_hp,
    max_hp: f32 = root.player_max_hp,
    /// Temporary shield, absorbed before HP (Juggernaut Halberd).
    shield: f32 = 0.0,
    xp: u32 = 0,
    /// XP needed to reach the next level (`upgrade.xpForLevel(level)`).
    xp_next: u32 = upgrade.xpForLevel(1),
    level: u16 = 1,
    weapons: [root.max_weapons]WeaponSlot = root.filledWithDefault(WeaponSlot, root.max_weapons),
    /// Passive levels, indexed 0..9 in DESIGN.md §3 table order; 0 = unowned.
    passives: [root.max_passives]u8 = @splat(0),
    /// Overclock counts, indexed by `id - 48` (damage, attack speed, max HP).
    ///
    /// `u32`, not `u8`: the counts are uncapped by design (DESIGN.md §3
    /// "Unlimited limit-break"), and a `u8` wrapped at 256 purchases, silently
    /// dropping the player's bonus. A `u32` cannot wrap in any reachable run —
    /// it would take more than four billion level-ups.
    overclock: [3]u32 = [_]u32{ 0, 0, 0 },
    /// Bit mask of the active synergies (DESIGN.md §3).
    synergy_mask: u16 = 0,
    input: InputFrame = .{},
    /// Last `input_seq` the server has applied; reported back to the client as
    /// `acked_seq` so it can reconcile its prediction ring buffer.
    last_input_seq: u32 = 0,
    /// Ticks of invulnerability left (Phase Katana's dash).
    invuln_ticks: u16 = 0,
    /// Kinetic Charge: charge accumulated by moving (DESIGN.md §3).
    kinetic_charge: f32 = 0.0,
    /// Cross-Slash Mastery: axe sweeps since the last reset.
    axe_swings: u8 = 0,
    /// Cross-Slash Mastery: reach bonus on the next sword attack.
    sword_reach_bonus: f32 = 0.0,
    /// Reactive Carapace: ticks until the shockwave can fire again.
    carapace_cd: u16 = 0,

    /// Integrate one fixed step. Pure function of `(input, dt, move_speed_mult)`.
    pub fn integrate(p: *PlayerState, dt: f32, move_speed_mult: f32) void {
        var mx: f32 = @as(f32, @floatFromInt(p.input.move_x)) / 100.0;
        var my: f32 = @as(f32, @floatFromInt(p.input.move_y)) / 100.0;

        // Keep diagonal movement at the same speed as axis-aligned movement.
        const mag = std.math.hypot(mx, my);
        if (mag > 1.0) {
            mx /= mag;
            my /= mag;
        }

        const speed = root.move_speed * move_speed_mult;
        p.vel[0] = mx * speed;
        p.vel[1] = my * speed;
        const dx = p.vel[0] * dt;
        const dy = p.vel[1] * dt;
        p.pos[0] += dx;
        p.pos[1] += dy;

        // Hard arena walls (DESIGN.md §1). The collider is clamped so the whole
        // 1.0 x 1.0 square stays inside [-1000, 1000].
        const limit = root.arena_half_size - root.player_half_extent;
        p.pos[0] = std.math.clamp(p.pos[0], -limit, limit);
        p.pos[1] = std.math.clamp(p.pos[1], -limit, limit);

        if (mag > 0.0001) p.aim_dir = .{ mx, my };

        // Kinetic Charge: 10 charge per unit travelled (DESIGN.md §3).
        if (p.synergy_mask & upgrade.synergy_kinetic_charge != 0) {
            p.kinetic_charge += 10.0 * std.math.hypot(dx, dy);
        }
    }
};

/// True when `pos` is within `r2` (a squared radius) of `centre`. The
/// interest test and the broadphase's circle query both want this, and
/// comparing in squared space keeps it a multiply and no square root.
fn inRadius(pos: [2]f32, centre: [2]f32, r2: f32) bool {
    const dx = pos[0] - centre[0];
    const dy = pos[1] - centre[1];
    return dx * dx + dy * dy <= r2;
}

/// Fixed-timestep simulation. One instance per running game.
pub const Simulation = struct {
    tick: u32 = 0,
    state: GameState = .running,
    /// Enemies killed since the run started.
    kills: u32 = 0,
    /// Set when the run ends, for `S2C_GAME_OVER`. The server clears it once it
    /// has sent the frame.
    game_over_pending: bool = false,
    final_tick: u32 = 0,

    players: [root.max_players]PlayerState = root.filledWithDefault(PlayerState, root.max_players),

    enemies: enemy.Pool = .{},
    projectiles: combat.ProjectilePool = .{},
    gems: gem.Pool = .{},
    rifts: evolve.RiftPool = .{},
    /// Broadphase over the enemy pool, rebuilt once per tick.
    grid: spatial.SpatialHash = .{},

    /// Spawn RNG. Seeded from a constant so a run is reproducible: the same
    /// seed and the same inputs produce the same enemies in the same places.
    rng: rng.Rng = rng.Rng.init(spawn_seed),
    /// Level-up choice RNG, separate from the spawn RNG.
    upgrade_rng: rng.Rng = rng.Rng.init(upgrade_seed),
    /// Fractional spawns carried between spawn evaluations, so the rate curve
    /// is not rounded down once per second.
    spawn_accum: f32 = 0.0,
    /// Enemies a wave owed but could not place because the active cap was
    /// reached. They are placed by a later wave rather than discarded, so
    /// sitting at the cap for a minute does not permanently lose the output of
    /// the curve during it.
    spawn_debt: usize = 0,
    /// When set, the world is held at this load every tick instead of being
    /// populated by the spawn curve. See `StressLoad`.
    stress: ?StressLoad = null,
    /// When set, every run starts with this loadout — the four level-1 weapons
    /// of DESIGN.md §3 replaced by it — on every join and every restart.
    ///
    /// **This is a test affordance, not part of the game.** It exists so a live
    /// client run can be started already holding a loadout normal play cannot
    /// reach in the time a scripted run survives: an evolution needs a level-8
    /// weapon *and* its named passive at max, roughly thirteen level-up picks,
    /// and a scripted run reaches level 6–7 before dying. Off in normal play;
    /// the server only turns it on from `--debug-loadout`. See `loadout.zig`.
    loadout: ?loadout.Loadout = null,

    /// Pending level-up offers, one per player whose XP bar filled.
    pending_levelups: [root.max_players]LevelUp = root.filledWithDefault(LevelUp, root.max_players),
    pending_count: usize = 0,
    next_event_id: u16 = 1,
    /// Set when a player's level, XP or item set changed, so the server knows
    /// to send an `S2C_LOADOUT`.
    loadout_dirty: [root.max_players]bool = @splat(false),

    /// Scratch space for the snapshot encoder; keeps encoding allocation-free.
    net_scratch: [root.max_players]wire.PlayerNet = root.filledWithDefault(wire.PlayerNet, root.max_players),
    net_enemies: [root.max_enemies]wire.EnemyNet = @splat(std.mem.zeroes(wire.EnemyNet)),
    net_projs: [root.max_projectiles]wire.ProjNet = @splat(std.mem.zeroes(wire.ProjNet)),
    net_gems: [root.max_gems]wire.GemNet = @splat(std.mem.zeroes(wire.GemNet)),
    /// Scratch space for broadphase results, shared by every query in a tick.
    /// Sized for the whole enemy pool because one query can legitimately match
    /// every enemy in the world.
    query_scratch: [root.max_enemies]u32 = @splat(0),
    /// Scratch space for the enemy indices a swing hit, so the evolution
    /// effects (pull, shield) can walk them.
    hit_scratch: [root.max_enemies]u32 = @splat(0),
    /// Scratch space for the Haste Aura elite indices, collected once per tick
    /// so every enemy can be tested against the aura field.
    aura_scratch: [root.max_enemies]u32 = @splat(0),

    pub fn init() Simulation {
        var self = Simulation{};
        for (0..root.max_players, &self.players) |i, *p| {
            p.id = @intCast(i);
            p.xp_next = upgrade.xpForLevel(1);
        }
        return self;
    }

    /// Elapsed simulation time, derived from `tick` so it never drifts.
    pub fn runTimeMs(self: *const Simulation) u32 {
        return self.tick * 1000 / root.tick_hz;
    }

    pub fn tickDurationSeconds() f32 {
        return 1.0 / @as(f32, @floatFromInt(root.tick_hz));
    }

    /// Reserve a player slot for `hello`. Returns `null` when full.
    pub fn spawnPlayer(self: *Simulation, requested_slot: u8) ?*PlayerState {
        if (requested_slot != 0) {
            if (requested_slot >= root.max_players) return null;
            if (self.players[requested_slot].active) return null;
            self.players[requested_slot].active = true;
            resetPlayer(&self.players[requested_slot], self.loadout);
            return &self.players[requested_slot];
        }
        for (&self.players) |*p| {
            if (!p.active) {
                p.active = true;
                resetPlayer(p, self.loadout);
                return p;
            }
        }
        return null;
    }

    /// Give a player a fresh run: the four level 1 weapons of DESIGN.md §3, no
    /// passives, level 1, full HP — plus `l` when one is set.
    fn resetPlayer(p: *PlayerState, l: ?loadout.Loadout) void {
        p.flags = .{ .alive = true };
        p.hp = root.player_max_hp;
        p.max_hp = root.player_max_hp;
        p.shield = 0.0;
        p.pos = .{ 0.0, 0.0 };
        p.vel = .{ 0.0, 0.0 };
        p.aim_dir = .{ 1.0, 0.0 };
        p.xp = 0;
        p.level = 1;
        p.xp_next = upgrade.xpForLevel(1);
        p.passives = @splat(0);
        p.overclock = [_]u32{ 0, 0, 0 };
        p.synergy_mask = 0;
        p.invuln_ticks = 0;
        p.kinetic_charge = 0.0;
        p.axe_swings = 0;
        p.sword_reach_bonus = 0.0;
        p.carapace_cd = 0;
        p.weapons = root.filledWithDefault(WeaponSlot, root.max_weapons);
        for (&p.weapons, 0..) |*slot, i| {
            slot.id = @intCast(i);
            slot.level = 1;
            slot.cooldown_ticks = 0;
            slot.evolved = false;
            slot.pending_slashes = 0;
            slot.pending_timer = 0;
            slot.shots_fired = 0;
        }
        if (l) |load| {
            load.apply(&p.weapons, &p.passives);
            p.synergy_mask = upgrade.synergyMask(&p.weapons, &p.passives);
        }
    }

    pub fn despawnPlayer(self: *Simulation, id: u8) void {
        if (id >= root.max_players) return;
        self.players[id].active = false;
    }

    /// Apply a `C2S_INPUT` to a player. Out-of-order and duplicate sequences are
    /// dropped, so `acked_seq` always reflects the newest input the server has
    /// actually integrated.
    pub fn applyInput(self: *Simulation, id: u8, input: wire.Input) void {
        if (id >= root.max_players) return;
        var p = &self.players[id];
        if (!p.active) return;
        if (input.input_seq <= p.last_input_seq) return;
        p.input = .{
            .input_seq = input.input_seq,
            .client_tick = input.client_tick,
            .move_x = input.move_x,
            .move_y = input.move_y,
            .aim_angle = input.aim_angle,
            .buttons = input.buttons,
        };
        p.last_input_seq = input.input_seq;
    }

    /// Advance the simulation one fixed step.
    ///
    /// The phase order is documented at the top of this file and is part of the
    /// determinism contract: two runs given the same inputs must produce the
    /// same world, so the systems cannot be reordered.
    pub fn advance(self: *Simulation) void {
        if (self.state == .game_over) return;
        if (self.state == .level_up_pause) {
            self.tickLevelUpPause();
            return;
        }
        const dt = tickDurationSeconds();

        for (&self.players) |*p| {
            if (!p.active or !p.flags.alive) continue;
            const stats = upgrade.resolveStats(&p.weapons, &p.passives, &p.overclock);
            p.integrate(dt, stats.move_speed_mult);

            // Nano Repair (DESIGN.md §3): HP restored per second.
            if (stats.regen_per_sec > 0.0 and p.hp < p.max_hp) {
                p.hp = @min(p.hp + stats.regen_per_sec * dt, p.max_hp);
            }
            if (p.invuln_ticks > 0) p.invuln_ticks -= 1;
            if (p.carapace_cd > 0) p.carapace_cd -= 1;
            // Shield is temporary and decays back to nothing over a few
            // seconds, so it cannot be banked indefinitely.
            if (p.shield > 0.0) p.shield = @max(p.shield - 2.0 * dt, 0.0);
        }

        self.updateEnemies(dt);
        self.rebuildGrid();
        // A Goliath crushes Tier 1 enemies out of its path (DESIGN.md §4): a
        // knockback impulse, applied here so it fits the tick's rule that only
        // knockback velocity moves between the grid build and the compaction.
        self.crushPass();
        self.updateWeapons();
        combat.updateProjectiles(
            &self.projectiles,
            &self.enemies,
            &self.grid,
            &self.query_scratch,
            dt,
            self.synergyMask(),
        );
        // Hostile projectiles (Spitter shots, the boss's burst) damage players.
        self.updateHostileProjectiles();
        self.updateContact();
        self.dropGems();

        const bosses_before = self.enemies.bossCount();
        self.kills += @intCast(self.enemies.reapDead());
        // `reapDead` compacts the pool, so the broadphase indices it left
        // behind no longer match the slots; rebuild before the shatter query
        // reads them.
        self.rebuildGrid();
        evolve.processShatter(&self.enemies, &self.grid, &self.query_scratch);
        self.projectiles.reapSpent();
        // A boss died this tick: its cache drops with its corpse and every
        // living player is offered an immediate draft (DESIGN.md §4).
        if (self.enemies.bossCount() < bosses_before) self.offerBossChest();

        self.updateGems(dt);
        evolve.updateRifts(&self.rifts, &self.enemies, &self.grid, &self.query_scratch, dt);
        self.rifts.reapExpired();
        self.enemies.tickShieldRegen();
        self.checkLevelUps();

        self.tick += 1;
        if (self.tick % enemy.spawn_interval_ticks == 0) self.spawnWave();
        if (self.stress) |load| self.topUpLoad(load.enemies, load.projectiles, load.radius);
    }

    /// Refill the world to a fixed load, spawning around the alive players'
    /// centroid.
    ///
    /// Used by the stress load above and by the benchmark, so both measure and
    /// serve exactly the same world. It draws from the simulation's own RNG, so
    /// a stress run is reproducible too.
    pub fn topUpLoad(
        self: *Simulation,
        want_enemies: usize,
        want_projectiles: usize,
        radius: f32,
    ) void {
        const around = self.playerCentroid() orelse return;
        const gun = weapon.spec(@intFromEnum(weapon.Id.gun)) orelse return;
        const t = @as(f32, @floatFromInt(self.tick)) /
            (@as(f32, @floatFromInt(root.tick_hz)) * 60.0);
        const hp_mult = enemy.hpMultiplier(t);

        while (self.projectiles.count < want_projectiles) {
            const angle = self.rng.range(0.0, 2.0 * std.math.pi);
            const dist = self.rng.range(2.0, radius);
            const dir = [2]f32{ @cos(angle), @sin(angle) };
            const pos = placeFrom(around, angle, dist);
            if (self.projectiles.spawn(0, gun, pos, dir) == null) break;
        }

        while (self.enemies.count < want_enemies) {
            const angle = self.rng.range(0.0, 2.0 * std.math.pi);
            const dist = self.rng.range(1.0, radius);
            const pos = placeFrom(around, angle, dist);
            // The stress load goes through the same spawn-time curve the real
            // spawner does, so the benchmark's world is the world the run
            // produces.
            if (self.enemies.spawnWith(.circle_t1, pos, .{
                .hp_mult = hp_mult,
                .speed_mult = enemy.speedMultiplier(t),
            }) == null) break;
        }
    }

    /// Place `dist` units from `centre` along `angle`, inside the arena.
    ///
    /// The ring the spawn curve draws is wider than the room left when the
    /// players stand against a wall, so an offset that would leave the arena is
    /// mirrored back across the centre rather than clamped per axis. Clamping
    /// per axis is what this used to do: it shortens the offset, so an enemy
    /// could end up closer to the players than the ring's inner radius — on top
    /// of them, against a wall — and the radial distribution flattened against
    /// the wall. Mirroring keeps the distance exact and biases only the angle,
    /// which is the smaller distortion and the only one available in a finite
    /// arena.
    fn placeFrom(centre: [2]f32, angle: f32, dist: f32) [2]f32 {
        const limit = root.arena_half_size - enemy.max_radius;
        var off = [2]f32{ @cos(angle) * dist, @sin(angle) * dist };
        if (@abs(centre[0] + off[0]) > limit) off[0] = -off[0];
        if (@abs(centre[1] + off[1]) > limit) off[1] = -off[1];
        return .{ centre[0] + off[0], centre[1] + off[1] };
    }

    /// Centroid of the alive players, or `null` when nobody is connected.
    pub fn playerCentroid(self: *const Simulation) ?[2]f32 {
        var sum = [2]f32{ 0.0, 0.0 };
        var n: u32 = 0;
        for (&self.players) |p| {
            if (!p.active or !p.flags.alive) continue;
            sum[0] += p.pos[0];
            sum[1] += p.pos[1];
            n += 1;
        }
        if (n == 0) return null;
        const f: f32 = @floatFromInt(n);
        return .{ sum[0] / f, sum[1] / f };
    }

    fn nearestPlayer(self: *const Simulation, from: [2]f32) ?usize {
        var best: ?usize = null;
        var best_d2 = std.math.inf(f32);
        for (&self.players, 0..) |p, i| {
            if (!p.active or !p.flags.alive) continue;
            const dx = p.pos[0] - from[0];
            const dy = p.pos[1] - from[1];
            const d2 = dx * dx + dy * dy;
            if (d2 < best_d2) {
                best_d2 = d2;
                best = i;
            }
        }
        return best;
    }

    /// Enemy AI, integration and the arena wall.
    ///
    /// DESIGN.md §1 calls the arena walls hard, and gives them for the player;
    /// enemies are clamped the same way so nothing can be pushed out of the
    /// world and out of the broadphase's covered range.
    ///
    /// Each archetype runs its own state machine (`darterStep`, `spitterStep`,
    /// `lancerStep`, `bossStep`); the circles and the boss pursue directly. A
    /// Haste Aura elite speeds up everything near it, and every enemy's facing
    /// is recorded for the wire.
    fn updateEnemies(self: *Simulation, dt: f32) void {
        const limit = root.arena_half_size;

        // Haste Aura elites (DESIGN.md §4): collect their positions first, so
        // every enemy this tick can be tested against the aura field. Elites
        // are rare, so the list is short and the per-enemy scan is cheap.
        var aura_count: usize = 0;
        for (0..self.enemies.count) |i| {
            if (self.enemies.elite_mask[i] & enemy.elite.haste_aura != 0) {
                self.aura_scratch[aura_count] = @intCast(i);
                aura_count += 1;
            }
        }

        var i: usize = 0;
        while (i < self.enemies.count) : (i += 1) {
            if (self.enemies.contact_cd[i] > 0) self.enemies.contact_cd[i] -= 1;
            if (self.enemies.marked_ticks[i] > 0) self.enemies.marked_ticks[i] -= 1;

            const archetype: enemy.Archetype = @enumFromInt(self.enemies.archetype[i]);
            const target = self.nearestPlayer(self.enemies.pos[i]);
            var vel = [2]f32{ 0.0, 0.0 };

            if (target) |pi| {
                const to_player = combat.sub(self.players[pi].pos, self.enemies.pos[i]);
                const dist = std.math.hypot(to_player[0], to_player[1]);
                const dir = combat.normalize(to_player);

                var speed = self.enemies.move_speed[i];
                // Haste Aura: +35% movement speed within 8.0 u of the source.
                if (self.inHasteAura(i, aura_count)) speed *= enemy.elite.haste_speed_mult;

                switch (archetype) {
                    .triangle_t1 => {
                        vel = self.darterStep(i, dir, dist);
                    },
                    .triangle_t2 => {
                        vel = self.spitterStep(i, dir, dist);
                    },
                    .triangle_t3 => {
                        vel = self.lancerStep(i, dir, dist);
                    },
                    .boss => {
                        vel = self.bossStep(i, dir, dist);
                    },
                    else => {
                        vel = .{ dir[0] * speed, dir[1] * speed };
                    },
                }
            } else {
                self.enemies.ai_state[i] = @intFromEnum(enemy.AiState.pursue);
                self.enemies.ai_timer[i] = 0;
            }

            // Cryo Flechette: a frozen enemy does not move; a slowed one moves
            // at the slowed factor (DESIGN.md §3).
            if (self.enemies.freeze_ticks[i] > 0) {
                self.enemies.freeze_ticks[i] -= 1;
                vel = .{ 0.0, 0.0 };
            } else if (self.enemies.slow_ticks[i] > 0) {
                self.enemies.slow_ticks[i] -= 1;
                vel[0] *= self.enemies.slow_factor[i];
                vel[1] *= self.enemies.slow_factor[i];
            }

            self.enemies.vel[i] = vel;

            // Facing follows movement, except for a telegraphing boss, which
            // stands still but faces the dash it is about to make: `bossStep`
            // locked that direction when the telegraph began, and that is how
            // the client learns the dash direction from `vel_angle`.
            const telegraphing = archetype == .boss and
                self.enemies.ai_state[i] == @intFromEnum(enemy.AiState.telegraph);
            if (!telegraphing and std.math.hypot(vel[0], vel[1]) > 1e-4) {
                const inv = 1.0 / std.math.hypot(vel[0], vel[1]);
                self.enemies.facing[i] = .{ vel[0] * inv, vel[1] * inv };
            }

            // Knockback decays towards nothing and is added on top of whatever
            // the AI asked for, so a shove interrupts the movement without
            // cancelling it.
            self.enemies.kb[i][0] *= enemy.knockback_decay;
            self.enemies.kb[i][1] *= enemy.knockback_decay;
            if (@abs(self.enemies.kb[i][0]) < 0.001) self.enemies.kb[i][0] = 0.0;
            if (@abs(self.enemies.kb[i][1]) < 0.001) self.enemies.kb[i][1] = 0.0;

            self.enemies.pos[i][0] += (vel[0] + self.enemies.kb[i][0]) * dt;
            self.enemies.pos[i][1] += (vel[1] + self.enemies.kb[i][1]) * dt;

            const edge = limit - self.enemies.radius[i];
            self.enemies.pos[i][0] = std.math.clamp(self.enemies.pos[i][0], -edge, edge);
            self.enemies.pos[i][1] = std.math.clamp(self.enemies.pos[i][1], -edge, edge);
        }
    }

    /// True when enemy `i` is within a Haste Aura elite's 8.0 u field. The
    /// source does not haste itself.
    fn inHasteAura(self: *const Simulation, i: usize, aura_count: usize) bool {
        for (0..aura_count) |k| {
            const src: usize = @intCast(self.aura_scratch[k]);
            if (src == i) continue;
            const dx = self.enemies.pos[i][0] - self.enemies.pos[src][0];
            const dy = self.enemies.pos[i][1] - self.enemies.pos[src][1];
            const r = enemy.elite.haste_radius + self.enemies.radius[i];
            if (dx * dx + dy * dy <= r * r) return true;
        }
        return false;
    }

    /// Triangle T1 (Darter): pursue, pause 0.4 s at 10 units, then lunge at
    /// 15 u/s along the direction locked when the pause ended (DESIGN.md §4).
    fn darterStep(self: *Simulation, i: usize, dir: [2]f32, dist: f32) [2]f32 {
        const state: enemy.AiState = @enumFromInt(self.enemies.ai_state[i]);
        switch (state) {
            .pursue => {
                if (dist <= enemy.darter.pause_range) {
                    self.enemies.ai_state[i] = @intFromEnum(enemy.AiState.windup);
                    self.enemies.ai_timer[i] = enemy.darter.pause_ticks;
                    return .{ 0.0, 0.0 };
                }
                return .{
                    dir[0] * self.enemies.move_speed[i],
                    dir[1] * self.enemies.move_speed[i],
                };
            },
            .windup => {
                if (self.enemies.ai_timer[i] > 0) self.enemies.ai_timer[i] -= 1;
                if (self.enemies.ai_timer[i] == 0) {
                    self.enemies.ai_state[i] = @intFromEnum(enemy.AiState.lunge);
                    self.enemies.ai_timer[i] = enemy.darter.lunge_ticks;
                    // The lunge starts on this tick, along the direction to the
                    // player as it stands now — that is the direction locked
                    // for the whole lunge, and it is what `vel` carries while
                    // the lunge runs.
                    return .{
                        dir[0] * enemy.darter.lunge_speed,
                        dir[1] * enemy.darter.lunge_speed,
                    };
                }
                return .{ 0.0, 0.0 };
            },
            .lunge => {
                if (self.enemies.ai_timer[i] > 0) self.enemies.ai_timer[i] -= 1;
                const locked = combat.normalize(self.enemies.vel[i]);
                if (self.enemies.ai_timer[i] == 0) {
                    self.enemies.ai_state[i] = @intFromEnum(enemy.AiState.pursue);
                    return .{
                        dir[0] * self.enemies.move_speed[i],
                        dir[1] * self.enemies.move_speed[i],
                    };
                }
                return .{
                    locked[0] * enemy.darter.lunge_speed,
                    locked[1] * enemy.darter.lunge_speed,
                };
            },
            // A darter never leaves pursue for these; they belong to the other
            // archetypes' state machines.
            else => {
                self.enemies.ai_state[i] = @intFromEnum(enemy.AiState.pursue);
                return .{
                    dir[0] * self.enemies.move_speed[i],
                    dir[1] * self.enemies.move_speed[i],
                };
            },
        }
    }

    /// Triangle T2 (Spitter): pursue until 18 units out, halt, and fire a 9.0 u/s
    /// hostile projectile (10 dmg) at the player every 2.5 s (DESIGN.md §4).
    fn spitterStep(self: *Simulation, i: usize, dir: [2]f32, dist: f32) [2]f32 {
        const state: enemy.AiState = @enumFromInt(self.enemies.ai_state[i]);
        const speed = self.enemies.move_speed[i];
        switch (state) {
            .pursue => {
                if (dist <= enemy.spitter.fire_range) {
                    self.enemies.ai_state[i] = @intFromEnum(enemy.AiState.halt);
                    self.enemies.ai_timer[i] = enemy.spitter.fire_interval_ticks;
                    return .{ 0.0, 0.0 };
                }
                return .{ dir[0] * speed, dir[1] * speed };
            },
            .halt => {
                if (dist > enemy.spitter.fire_range + enemy.spitter.resume_band) {
                    self.enemies.ai_state[i] = @intFromEnum(enemy.AiState.pursue);
                    return .{ dir[0] * speed, dir[1] * speed };
                }
                if (self.enemies.ai_timer[i] > 0) self.enemies.ai_timer[i] -= 1;
                if (self.enemies.ai_timer[i] == 0) {
                    self.enemies.ai_timer[i] = enemy.spitter.fire_interval_ticks;
                    self.fireHostile(i, dir, enemy.spitter.shot_speed, enemy.spitter.shot_damage, enemy.spitter.shot_ttl_ticks);
                }
                return .{ 0.0, 0.0 };
            },
            else => {
                self.enemies.ai_state[i] = @intFromEnum(enemy.AiState.pursue);
                return .{ dir[0] * speed, dir[1] * speed };
            },
        }
    }

    /// Triangle T3 (Lancer): pursue, and every 4.0 s lock a charge vector and
    /// charge 24.0 units at 20.0 u/s, knockback-immune while charging
    /// (DESIGN.md §4). The charge is 1.2 s of the 4.0 s cycle, so the next lock
    /// lands one full interval after the last.
    fn lancerStep(self: *Simulation, i: usize, dir: [2]f32, dist: f32) [2]f32 {
        _ = dist;
        const state: enemy.AiState = @enumFromInt(self.enemies.ai_state[i]);
        const speed = self.enemies.move_speed[i];
        switch (state) {
            .pursue => {
                self.enemies.kb_resist[i] = 0.0;
                if (self.enemies.ai_timer[i] > 0) self.enemies.ai_timer[i] -= 1;
                if (self.enemies.ai_timer[i] == 0) {
                    self.enemies.ai_state[i] = @intFromEnum(enemy.AiState.charge);
                    self.enemies.ai_timer[i] = enemy.lancer.charge_ticks;
                    self.enemies.facing[i] = dir;
                    self.enemies.kb_resist[i] = 1.0;
                    return .{
                        dir[0] * enemy.lancer.charge_speed,
                        dir[1] * enemy.lancer.charge_speed,
                    };
                }
                return .{ dir[0] * speed, dir[1] * speed };
            },
            .charge => {
                self.enemies.kb_resist[i] = 1.0;
                if (self.enemies.ai_timer[i] > 0) self.enemies.ai_timer[i] -= 1;
                const locked = combat.normalize(self.enemies.vel[i]);
                if (self.enemies.ai_timer[i] == 0) {
                    self.enemies.ai_state[i] = @intFromEnum(enemy.AiState.pursue);
                    self.enemies.ai_timer[i] = enemy.lancer.lock_interval_ticks - enemy.lancer.charge_ticks;
                    self.enemies.kb_resist[i] = 0.0;
                    return .{ dir[0] * speed, dir[1] * speed };
                }
                return .{
                    locked[0] * enemy.lancer.charge_speed,
                    locked[1] * enemy.lancer.charge_speed,
                };
            },
            else => {
                self.enemies.ai_state[i] = @intFromEnum(enemy.AiState.pursue);
                return .{ dir[0] * speed, dir[1] * speed };
            },
        }
    }

    /// Boss (DESIGN.md §4): pursue the player, and every 3.0 s alternate a
    /// 12-projectile radial burst with a telegraphed 22.0 u/s dash. The dash is
    /// announced by a 1.0 s warning — the boss stands still and faces the locked
    /// direction, which is what the client reads from `vel_angle` — then runs
    /// for 1.0 s. The post-dash timer keeps attacks 3.0 s apart.
    fn bossStep(self: *Simulation, i: usize, dir: [2]f32, dist: f32) [2]f32 {
        _ = dist;
        const state: enemy.AiState = @enumFromInt(self.enemies.ai_state[i]);
        const speed = self.enemies.move_speed[i];
        switch (state) {
            .pursue => {
                if (self.enemies.ai_timer[i] > 0) self.enemies.ai_timer[i] -= 1;
                if (self.enemies.ai_timer[i] == 0) {
                    if (self.enemies.boss_parity[i] == 0) {
                        self.fireBurst(i);
                        self.enemies.boss_parity[i] = 1;
                        self.enemies.ai_timer[i] = enemy.boss.attack_interval_ticks;
                    } else {
                        self.enemies.ai_state[i] = @intFromEnum(enemy.AiState.telegraph);
                        self.enemies.ai_timer[i] = enemy.boss.telegraph_ticks;
                        self.enemies.boss_parity[i] = 0;
                        self.enemies.facing[i] = dir;
                    }
                    return .{ 0.0, 0.0 };
                }
                return .{ dir[0] * speed, dir[1] * speed };
            },
            .telegraph => {
                if (self.enemies.ai_timer[i] > 0) self.enemies.ai_timer[i] -= 1;
                if (self.enemies.ai_timer[i] == 0) {
                    self.enemies.ai_state[i] = @intFromEnum(enemy.AiState.lunge);
                    self.enemies.ai_timer[i] = enemy.boss.dash_ticks;
                    return .{
                        self.enemies.facing[i][0] * enemy.boss.dash_speed,
                        self.enemies.facing[i][1] * enemy.boss.dash_speed,
                    };
                }
                return .{ 0.0, 0.0 };
            },
            .lunge => {
                if (self.enemies.ai_timer[i] > 0) self.enemies.ai_timer[i] -= 1;
                const locked = self.enemies.facing[i];
                if (self.enemies.ai_timer[i] == 0) {
                    self.enemies.ai_state[i] = @intFromEnum(enemy.AiState.pursue);
                    self.enemies.ai_timer[i] = enemy.boss.attack_interval_ticks -
                        enemy.boss.telegraph_ticks - enemy.boss.dash_ticks;
                    return .{ dir[0] * speed, dir[1] * speed };
                }
                return .{
                    locked[0] * enemy.boss.dash_speed,
                    locked[1] * enemy.boss.dash_speed,
                };
            },
            else => {
                self.enemies.ai_state[i] = @intFromEnum(enemy.AiState.pursue);
                return .{ dir[0] * speed, dir[1] * speed };
            },
        }
    }

    /// Fire one hostile (enemy-owned) projectile from enemy `i` along `dir`.
    ///
    /// `owner_id = 0xff` marks the shot as hostile: it damages players rather
    /// than enemies, and the client renders it as an enemy shot.
    fn fireHostile(
        self: *Simulation,
        i: usize,
        dir: [2]f32,
        speed: f32,
        damage: f32,
        ttl_ticks: u16,
    ) void {
        var spec = weapon.zero_spec;
        spec.shape = .circle;
        spec.speed = speed;
        spec.damage = damage;
        spec.radius = 0.4;
        spec.pierce = 1;
        spec.ttl_ticks = ttl_ticks;
        spec.knockback = 0.0;
        _ = self.projectiles.spawn(0xff, spec, self.enemies.pos[i], dir);
    }

    /// The boss's radial burst: 12 projectiles evenly spaced around the circle
    /// (DESIGN.md §4).
    fn fireBurst(self: *Simulation, i: usize) void {
        var k: usize = 0;
        while (k < enemy.boss.burst_count) : (k += 1) {
            const a = @as(f32, @floatFromInt(k)) *
                (2.0 * std.math.pi / @as(f32, @floatFromInt(enemy.boss.burst_count)));
            self.fireHostile(
                i,
                .{ @cos(a), @sin(a) },
                enemy.boss.burst_speed,
                enemy.boss.burst_damage,
                enemy.boss.burst_ttl_ticks,
            );
        }
    }

    fn rebuildGrid(self: *Simulation) void {
        self.grid.clear();
        var i: usize = 0;
        while (i < self.enemies.count) : (i += 1) {
            _ = self.grid.insert(@intCast(i), self.enemies.pos[i]);
        }
        // The grid is sized for the whole pool, so a rebuild covers all of it.
        // An enemy missing from the broadphase is one no weapon can ever hit,
        // and nothing would say so — hence the assert rather than a comment.
        std.debug.assert(self.grid.len == self.enemies.count);
    }

    /// Tick every weapon cooldown and fire what is ready.
    ///
    /// The nearest enemy is looked up once per player per tick rather than once
    /// per weapon: with four weapons that is four broadphase queries saved, and
    /// all four aim at the same target anyway.
    fn updateWeapons(self: *Simulation) void {
        for (&self.players) |*p| {
            if (!p.active or !p.flags.alive) continue;
            const stats = upgrade.resolveStats(&p.weapons, &p.passives, &p.overclock);

            // Cooldowns and the Sword L8 follow-up slashes tick first.
            for (&p.weapons) |*slot| {
                if (slot.cooldown_ticks > 0) slot.cooldown_ticks -= 1;
                if (slot.pending_slashes > 0 and slot.pending_timer > 0) slot.pending_timer -= 1;
            }

            const target = combat.nearestEnemy(
                &self.grid,
                &self.enemies,
                p.pos,
                acquire_range,
                &self.query_scratch,
            ) orelse continue;

            const dir = combat.normalize(combat.sub(self.enemies.pos[target], p.pos));

            for (&p.weapons) |*slot| {
                if (slot.cooldown_ticks > 0) continue;
                const base = weapon.specFor(slot.id, slot.level) orelse continue;
                const spec = upgrade.resolveSpec(base, stats);
                self.fireWeapon(p, slot, spec, dir);
                slot.cooldown_ticks = spec.cooldown_ticks;
                if (spec.slashes_per_cycle > 1) {
                    slot.pending_slashes = spec.slashes_per_cycle - 1;
                    slot.pending_timer = weapon.secondsToTicks(0.20);
                }
            }

            for (&p.weapons) |*slot| {
                if (slot.pending_slashes == 0 or slot.pending_timer > 0) continue;
                const base = weapon.specFor(slot.id, slot.level) orelse continue;
                const spec = upgrade.resolveSpec(base, stats);
                self.fireWeapon(p, slot, spec, dir);
                slot.pending_slashes -= 1;
                slot.pending_timer = weapon.secondsToTicks(0.20);
            }
        }
    }

    /// Fire one weapon once with an already-resolved spec.
    ///
    /// `slot` is only touched for the Gun's per-slot shot counter, which is what
    /// decides whether a round explodes; cooldowns are the caller's business.
    fn fireWeapon(
        self: *Simulation,
        p: *PlayerState,
        slot: *WeaponSlot,
        spec: weapon.Spec,
        dir: [2]f32,
    ) void {
        // Kinetic Charge: at 100 charge the activation gains +40% damage and
        // +50% projectile speed (DESIGN.md §3).
        var spec_mut = spec;
        if (p.synergy_mask & upgrade.synergy_kinetic_charge != 0 and p.kinetic_charge >= 100.0) {
            spec_mut.damage *= 1.4;
            spec_mut.speed *= 1.5;
            p.kinetic_charge = 0.0;
        }

        // Cross-Slash Mastery: every third axe sweep resets the sword's
        // cooldown and grants +50% reach to its next attack.
        // An evolved axe is still an axe, so the check is on the base weapon.
        if (p.synergy_mask & upgrade.synergy_cross_slash != 0 and
            upgrade.baseWeaponId(spec_mut.id) == upgrade.ids.axe)
        {
            p.axe_swings +%= 1;
            if (p.axe_swings % 3 == 0) {
                if (upgrade.weaponSlot(&p.weapons, upgrade.ids.sword)) |si| {
                    p.weapons[si].cooldown_ticks = 0;
                }
                p.sword_reach_bonus = 0.5;
            }
        }
        if (p.sword_reach_bonus > 0.0 and
            upgrade.baseWeaponId(spec_mut.id) == upgrade.ids.sword)
        {
            spec_mut.reach *= 1.0 + p.sword_reach_bonus;
            p.sword_reach_bonus = 0.0;
        }

        if (weapon.isArc(spec_mut)) {
            const hits = combat.fireArc(
                &self.enemies,
                &self.grid,
                &self.projectiles,
                p.id,
                spec_mut,
                p.pos,
                dir,
                &self.query_scratch,
                &self.hit_scratch,
            );

            if (spec_mut.dash_distance > 0.0) {
                p.pos[0] += p.aim_dir[0] * spec_mut.dash_distance;
                p.pos[1] += p.aim_dir[1] * spec_mut.dash_distance;
                const limit = root.arena_half_size - root.player_half_extent;
                p.pos[0] = std.math.clamp(p.pos[0], -limit, limit);
                p.pos[1] = std.math.clamp(p.pos[1], -limit, limit);
                p.flags.invulnerable = true;
                p.invuln_ticks = spec_mut.dash_invuln_ticks;
            }
            if (spec_mut.pull_inward > 0.0) {
                for (self.hit_scratch[0..hits]) |ei| {
                    const e: usize = ei;
                    const to = combat.sub(p.pos, self.enemies.pos[e]);
                    const d = std.math.hypot(to[0], to[1]);
                    if (d <= 1e-4) continue;
                    const pull = @min(spec_mut.pull_inward, d);
                    self.enemies.pos[e][0] += (to[0] / d) * pull;
                    self.enemies.pos[e][1] += (to[1] / d) * pull;
                }
            }
            if (spec_mut.rift_dps > 0.0) {
                _ = self.rifts.spawn(p.pos, spec_mut.rift_radius, spec_mut.rift_dps, spec_mut.rift_ticks);
            }
            if (spec_mut.shield_per_hit > 0.0 and hits > 0) {
                p.shield = @min(p.shield + spec_mut.shield_per_hit * @as(f32, @floatFromInt(hits)), spec_mut.shield_cap);
            }
            return;
        }

        if (spec_mut.shape == .ray and spec_mut.speed == 0.0) {
            _ = combat.fireHitscan(
                &self.enemies,
                &self.grid,
                &self.projectiles,
                p.id,
                spec_mut,
                p.pos,
                dir,
                &self.query_scratch,
            );
            return;
        }

        const before = self.projectiles.count;
        combat.spawnVolley(&self.projectiles, p.id, spec_mut, p.pos, dir);
        if (spec_mut.explosive_every > 0) {
            slot.shots_fired +%= 1;
            if (slot.shots_fired % spec_mut.explosive_every == 0) {
                for (before..self.projectiles.count) |k| self.projectiles.explosive[k] = true;
            }
        }
    }

    /// Contact damage: an enemy overlapping a player's 1.0 x 1.0 square hurts
    /// it, at most once per `enemy.contact_cooldown_ticks`.
    ///
    /// Titanium Plating reduces the damage taken, shield absorbs what is left,
    /// and a player reaching 0 HP ends the run.
    fn updateContact(self: *Simulation) void {
        const half = root.player_half_extent;
        const reach = half * std.math.sqrt2 + enemy.max_radius;

        for (&self.players) |*p| {
            if (!p.active or !p.flags.alive) continue;
            const stats = upgrade.resolveStats(&p.weapons, &p.passives, &p.overclock);
            if (p.flags.invulnerable or p.invuln_ticks > 0) continue;

            const n = self.grid.queryCircle(p.pos, reach, &self.query_scratch);
            for (self.query_scratch[0..n]) |ei| {
                const e: usize = ei;
                if (self.enemies.contact_cd[e] > 0) continue;
                if (!combat.boxCircleOverlap(p.pos, half, self.enemies.pos[e], self.enemies.radius[e])) {
                    continue;
                }
                self.enemies.contact_cd[e] = enemy.contact_cooldown_ticks;

                const raw = self.enemies.contact_dmg[e];
                // Titanium Plating: -3 flat damage taken, minimum 1.
                var taken = @max(raw - stats.armor_flat, 1.0);
                if (p.shield > 0.0) {
                    const absorbed = @min(p.shield, taken);
                    p.shield -= absorbed;
                    taken -= absorbed;
                }
                p.hp -= taken;

                // Vampiric: restores 15% max HP upon damaging a player
                // (DESIGN.md §4).
                if (self.enemies.elite_mask[e] & enemy.elite.vampiric != 0) {
                    self.enemies.hp[e] = @min(
                        self.enemies.hp[e] + enemy.elite.vampiric_heal * self.enemies.max_hp[e],
                        self.enemies.max_hp[e],
                    );
                }

                // Reactive Carapace: taking contact damage emits a 4.0 u radial
                // shockwave for 12 x Regen damage (DESIGN.md §3).
                if (p.synergy_mask & upgrade.synergy_reactive_carapace != 0 and p.carapace_cd == 0) {
                    const dmg = 12.0 * stats.regen_per_sec;
                    const m = self.grid.queryCircle(p.pos, 4.0 + enemy.max_radius, &self.query_scratch);
                    for (self.query_scratch[0..m]) |ej| {
                        const other: usize = ej;
                        if (!combat.circlesOverlap(p.pos, 4.0, self.enemies.pos[other], self.enemies.radius[other])) continue;
                        _ = self.enemies.applyHit(other, dmg, combat.normalize(combat.sub(self.enemies.pos[other], p.pos)), 0.0);
                    }
                    p.carapace_cd = root.tick_hz;
                }

                if (p.hp <= 0.0) {
                    p.hp = 0.0;
                    p.flags.alive = false;
                    self.killPlayer(p.id);
                }
            }
        }
    }

    /// Circle T3 (Goliath): crushes Tier 1 enemies out of its path (DESIGN.md
    /// §4). A Goliath shoves aside any Tier 1 enemy its body overlaps, as a
    /// knockback impulse rather than damage, so the shove shows up as movement
    /// over the next ticks and not as lost health.
    fn crushPass(self: *Simulation) void {
        for (0..self.enemies.count) |i| {
            if (self.enemies.archetype[i] != @intFromEnum(enemy.Archetype.circle_t3)) continue;
            const reach = self.enemies.radius[i] + enemy.max_radius;
            const n = self.grid.queryCircle(self.enemies.pos[i], reach, &self.query_scratch);
            for (self.query_scratch[0..n]) |ej| {
                const e: usize = ej;
                if (e == i) continue;
                const a: enemy.Archetype = @enumFromInt(self.enemies.archetype[e]);
                if (a != .circle_t1 and a != .triangle_t1) continue;
                if (!combat.circlesOverlap(
                    self.enemies.pos[i],
                    self.enemies.radius[i],
                    self.enemies.pos[e],
                    self.enemies.radius[e],
                )) continue;
                const away = combat.normalize(combat.sub(self.enemies.pos[e], self.enemies.pos[i]));
                self.enemies.kb[e][0] += away[0] * 6.0;
                self.enemies.kb[e][1] += away[1] * 6.0;
            }
        }
    }

    /// Resolve hostile (enemy-owned) projectiles against the players.
    ///
    /// A hostile projectile damages the player it overlaps, reduced by armor
    /// and absorbed by shield exactly as contact damage is, then is spent.
    fn updateHostileProjectiles(self: *Simulation) void {
        const half = root.player_half_extent;
        var i: usize = 0;
        while (i < self.projectiles.count) : (i += 1) {
            if (self.projectiles.owner_id[i] != 0xff) continue;
            if (self.projectiles.ttl_ticks[i] == 0) continue;
            for (&self.players) |*p| {
                if (!p.active or !p.flags.alive) continue;
                if (p.flags.invulnerable or p.invuln_ticks > 0) continue;
                if (!combat.boxCircleOverlap(
                    p.pos,
                    half,
                    self.projectiles.pos[i],
                    self.projectiles.spec[i].radius,
                )) continue;

                const stats = upgrade.resolveStats(&p.weapons, &p.passives, &p.overclock);
                var taken = @max(self.projectiles.damage[i] - stats.armor_flat, 1.0);
                if (p.shield > 0.0) {
                    const absorbed = @min(p.shield, taken);
                    p.shield -= absorbed;
                    taken -= absorbed;
                }
                p.hp -= taken;
                self.projectiles.ttl_ticks[i] = 0;

                if (p.hp <= 0.0) {
                    p.hp = 0.0;
                    p.flags.alive = false;
                    self.killPlayer(p.id);
                }
                break;
            }
        }
    }

    /// Spawn a gem at every enemy that died this tick (DESIGN.md §4).
    fn dropGems(self: *Simulation) void {
        for (0..self.enemies.count) |i| {
            if (self.enemies.hp[i] > 0.0) continue;
            _ = self.gems.spawn(
                self.enemies.pos[i],
                gem.gemValue(self.enemies.archetype[i], self.enemies.elite_mask[i]),
            );
        }
    }

    /// Magnetize, fly and collect gems, awarding XP.
    fn updateGems(self: *Simulation, dt: f32) void {
        var i: usize = 0;
        while (i < self.gems.count) {
            if (self.gems.magnet_target[i] == gem.no_magnet) {
                for (&self.players) |*p| {
                    if (!p.active or !p.flags.alive) continue;
                    const stats = upgrade.resolveStats(&p.weapons, &p.passives, &p.overclock);
                    const d = combat.sub(p.pos, self.gems.pos[i]);
                    if (d[0] * d[0] + d[1] * d[1] <= stats.pickup_radius * stats.pickup_radius) {
                        self.gems.magnet_target[i] = p.id;
                        break;
                    }
                }
            }

            const target = self.gems.magnet_target[i];
            if (target == gem.no_magnet) {
                i += 1;
                continue;
            }
            const p = &self.players[target];
            if (!p.active or !p.flags.alive) {
                self.gems.magnet_target[i] = gem.no_magnet;
                i += 1;
                continue;
            }

            const to = combat.sub(p.pos, self.gems.pos[i]);
            const dist = std.math.hypot(to[0], to[1]);
            if (dist <= gem_collect_radius) {
                self.gainXp(target, self.gems.xp_value[i]);
                self.gems.swapRemove(i);
                continue;
            }

            const dir = combat.normalize(to);
            self.gems.pos[i][0] += dir[0] * gem_magnet_speed * dt;
            self.gems.pos[i][1] += dir[1] * gem_magnet_speed * dt;

            // Singularity Field: a magnetized gem deals 15 kinetic damage to
            // enemies it passes through (DESIGN.md §3).
            if (p.synergy_mask & upgrade.synergy_singularity_field != 0) {
                const n = self.grid.queryCircle(self.gems.pos[i], 0.5 + enemy.max_radius, &self.query_scratch);
                for (self.query_scratch[0..n]) |ei| {
                    const e: usize = ei;
                    if (!combat.circlesOverlap(self.gems.pos[i], 0.5, self.enemies.pos[e], self.enemies.radius[e])) continue;
                    _ = self.enemies.applyHit(e, 15.0, combat.normalize(combat.sub(self.enemies.pos[e], self.gems.pos[i])), 0.0);
                }
            }
            i += 1;
        }
    }

    /// Award XP to a player.
    pub fn gainXp(self: *Simulation, player_id: u8, amount: u32) void {
        if (player_id >= root.max_players) return;
        const p = &self.players[player_id];
        if (!p.active or !p.flags.alive) return;
        p.xp += amount;
        self.loadout_dirty[player_id] = true;
    }

    /// Offer a level-up to every player whose XP bar filled, and pause.
    fn checkLevelUps(self: *Simulation) void {
        for (&self.players) |*p| {
            if (!p.active or !p.flags.alive) continue;
            if (p.xp < p.xp_next) continue;
            p.xp -= p.xp_next;
            self.offerDraft(p);
        }
        if (self.pending_count > 0) self.state = .level_up_pause;
    }

    /// A boss died: offer every living player an immediate evolution/upgrade
    /// draft, reusing the level-up machinery (DESIGN.md §4). The boss's 250 XP
    /// cache is a separate gem, dropped with its corpse and collected normally.
    fn offerBossChest(self: *Simulation) void {
        for (&self.players) |*p| {
            if (!p.active or !p.flags.alive) continue;
            self.offerDraft(p);
        }
        if (self.pending_count > 0) self.state = .level_up_pause;
    }

    /// Queue one level-up draft for a player: a level, three weighted choices
    /// and the pause. Shared by a filled XP bar and a boss chest, so the two
    /// paths cannot drift apart.
    fn offerDraft(self: *Simulation, p: *PlayerState) void {
        p.level += 1;
        p.xp_next = upgrade.xpForLevel(p.level);
        const options = upgrade.generateOptions(&p.weapons, &p.passives, &p.overclock, &self.upgrade_rng);
        self.pending_levelups[self.pending_count] = .{
            .event_id = self.next_event_id,
            .player_id = p.id,
            .new_level = p.level,
            .options = options,
            .timeout_ticks = levelup_timeout_ticks,
            .resolved = false,
            .sent = false,
        };
        self.next_event_id +%= 1;
        self.pending_count += 1;
        self.loadout_dirty[p.id] = true;
    }

    /// Advance a paused run: count down the offer timeouts and auto-select
    /// option 0 for any that expire.
    fn tickLevelUpPause(self: *Simulation) void {
        // A pause with nothing pending is a degenerate state a test can create
        // by setting the state directly; it stays paused.
        if (self.pending_count == 0) return;

        var all_resolved = true;
        for (self.pending_levelups[0..self.pending_count]) |*ev| {
            if (ev.resolved) continue;
            if (ev.timeout_ticks > 0) ev.timeout_ticks -= 1;
            if (ev.timeout_ticks == 0) {
                self.applyOption(ev.player_id, ev.options[0]);
                ev.resolved = true;
            }
            if (!ev.resolved) all_resolved = false;
        }
        if (all_resolved) self.resumeFromPause();
    }

    /// Answer a pending level-up offer.
    ///
    /// Returns `false` when the event is unknown, already resolved, or the
    /// choice index is out of range's slot.
    pub fn submitChoice(self: *Simulation, player_id: u8, event_id: u16, choice_idx: u8) bool {
        for (self.pending_levelups[0..self.pending_count]) |*ev| {
            if (ev.player_id != player_id or ev.event_id != event_id) continue;
            if (ev.resolved) return false;
            const idx: usize = @min(choice_idx, 2);
            self.applyOption(player_id, ev.options[idx]);
            ev.resolved = true;
            self.maybeResumeFromPause();
            return true;
        }
        return false;
    }

    fn maybeResumeFromPause(self: *Simulation) void {
        for (self.pending_levelups[0..self.pending_count]) |ev| {
            if (!ev.resolved) return;
        }
        self.resumeFromPause();
    }

    fn resumeFromPause(self: *Simulation) void {
        self.pending_count = 0;
        self.state = .running;
    }

    /// Apply a chosen upgrade to a player's loadout.
    fn applyOption(self: *Simulation, player_id: u8, opt: upgrade.UpgradeOption) void {
        const p = &self.players[player_id];

        if (opt.is_evo) {
            if (upgrade.evolutionById(opt.item_id)) |evo| {
                if (upgrade.weaponSlot(&p.weapons, evo.weapon_id)) |i| {
                    upgrade.fuseInto(&p.weapons[i], evo);
                }
            }
        } else if (opt.item_id < root.max_weapons) {
            if (upgrade.weaponSlot(&p.weapons, opt.item_id)) |i| {
                p.weapons[i].level = @min(p.weapons[i].level + 1, root.max_weapon_level);
            } else {
                for (&p.weapons) |*slot| {
                    if (!slot.isFree()) continue;
                    slot.id = opt.item_id;
                    slot.level = 1;
                    slot.cooldown_ticks = 0;
                    slot.evolved = false;
                    slot.pending_slashes = 0;
                    slot.pending_timer = 0;
                    slot.shots_fired = 0;
                    break;
                }
            }
        } else if (upgrade.isOverclockId(opt.item_id)) {
            const i: usize = opt.item_id - upgrade.ids.overclock_damage;
            // Plain `+=` on the `u32` counter: no wrapping add, so the count
            // cannot silently fall back to zero the way the old `+%=` on `u8`
            // did at 256 purchases.
            p.overclock[i] += 1;
            if (i == 2) {
                p.max_hp += 25.0;
                p.hp += 25.0;
            }
        } else if (upgrade.passiveIndex(opt.item_id)) |i| {
            const max = upgrade.passiveMaxLevelById(opt.item_id) orelse return;
            p.passives[i] = @min(p.passives[i] + 1, max);
        }

        p.synergy_mask = upgrade.synergyMask(&p.weapons, &p.passives);
        self.loadout_dirty[player_id] = true;
    }

    /// End the run for a player and, when nobody is left, report game over.
    fn killPlayer(self: *Simulation, player_id: u8) void {
        self.loadout_dirty[player_id] = true;
        if (self.alivePlayerCount() > 0) return;
        self.state = .game_over;
        self.final_tick = self.tick;
        self.game_over_pending = true;
    }

    /// Start a fresh run on a connection: reset the world and every connected
    /// player.
    ///
    /// Phase 3 is a single-player phase, so a restart resets the whole run
    /// rather than only the requesting player; party-level restart semantics
    /// are phase 5.
    pub fn restart(self: *Simulation, player_id: u8) void {
        _ = player_id;
        self.tick = 0;
        self.kills = 0;
        self.spawn_accum = 0.0;
        self.spawn_debt = 0;
        self.state = .running;
        self.game_over_pending = false;
        self.final_tick = 0;
        self.pending_count = 0;
        self.next_event_id = 1;

        self.enemies.count = 0;
        self.enemies.next_id = 1;
        self.enemies.shatter_count = 0;
        self.projectiles.count = 0;
        self.projectiles.next_id = 1;
        self.gems.count = 0;
        self.gems.next_id = 1;
        self.rifts.count = 0;

        for (&self.players) |*p| {
            if (!p.active) continue;
            resetPlayer(p, self.loadout);
            self.loadout_dirty[p.id] = true;
        }
    }

    /// Score for a player (DESIGN.md §1):
    /// `(seconds survived x 10) + (level x 250) + (kills x 2)`.
    pub fn scoreFor(self: *const Simulation, player_id: u8) u32 {
        const p = &self.players[player_id];
        const seconds: u32 = @intCast(self.tick / root.tick_hz);
        return seconds * 10 + @as(u32, p.level) * 250 + self.kills * 2;
    }

    /// Bit mask of the synergies the party has armed.
    fn synergyMask(self: *const Simulation) u16 {
        var mask: u16 = 0;
        for (&self.players) |p| {
            if (p.active and p.flags.alive) mask |= p.synergy_mask;
        }
        return mask;
    }

    /// Evaluate the spawn formula (DESIGN.md §4) and place the enemies it owes.
    ///
    /// The fractional part of the rate is carried in `spawn_accum`, so a rate
    /// of 3.6 enemies/second produces a fourth enemy every few seconds instead
    /// of being rounded down to 3 forever.
    pub fn spawnWave(self: *Simulation) void {
        const players = self.activePlayerCount();
        if (players == 0) return;

        const t = @as(f32, @floatFromInt(self.tick)) /
            (@as(f32, @floatFromInt(root.tick_hz)) * 60.0);
        var rate = enemy.spawnRate(t, players);
        if (enemy.surgeActive(self.tick)) rate *= enemy.surge_multiplier;

        self.spawn_accum += rate;
        var owed: usize = @intFromFloat(@floor(self.spawn_accum));
        self.spawn_accum -= @as(f32, @floatFromInt(owed));
        // Whatever the last wave could not place is still owed. Saturating
        // addition, not a clamp at the pool size: the debt is paid out over as
        // many waves as it takes, so clamping it to what a single wave could
        // place would silently drop the rest in exactly the saturated,
        // endlessly-escalating case the debt exists for.
        owed +|= self.spawn_debt;
        self.spawn_debt = 0;

        const cap = enemy.activeCap(t);
        const centroid = self.playerCentroid() orelse return;
        // One axis per wave: a surge has to cluster the whole wave into two
        // opposing arcs, which only works if every enemy is measured from the
        // same direction.
        const axis = enemy.surgeAxis(&self.rng, self.tick);
        // The difficulty curve (DESIGN.md §1) scales every spawn's health.
        const hp_mult = enemy.hpMultiplier(t);

        while (owed > 0) : (owed -= 1) {
            if (self.enemies.count >= cap) {
                // Banked rather than discarded: a later wave places these as
                // soon as the cap allows. The debt is only bounded by the
                // counter's range — it drains a wave's worth at a time, so any
                // clamp smaller than the total owed would lose spawns under
                // sustained saturation.
                self.spawn_debt +|= owed;
                break;
            }
            const archetype = enemy.pickArchetype(&self.rng, self.tick);
            const angle = enemy.spawnAngle(&self.rng, axis);
            const dist = self.rng.range(enemy.spawn_min_radius, enemy.spawn_max_radius);
            const pos = placeFrom(centroid, angle, dist);
            self.spawnEnemy(archetype, pos, hp_mult);
        }

        // Boss cadence: every 180 s, if none is alive (DESIGN.md §4).
        if (self.tick >= enemy.boss.interval_ticks and
            @mod(self.tick, enemy.boss.interval_ticks) == 0 and
            self.enemies.bossCount() == 0)
        {
            const angle = self.rng.range(0.0, 2.0 * std.math.pi);
            const dist = self.rng.range(enemy.spawn_min_radius, enemy.spawn_max_radius);
            self.spawnBoss(placeFrom(centroid, angle, dist), hp_mult, players);
        }
    }

    /// Spawn one enemy of `archetype` at `pos`, applying the difficulty curve's
    /// health multiplier and the elite roll (DESIGN.md §1, §4).
    fn spawnEnemy(self: *Simulation, archetype: enemy.Archetype, pos: [2]f32, hp_mult: f32) void {
        const t = @as(f32, @floatFromInt(self.tick)) /
            (@as(f32, @floatFromInt(root.tick_hz)) * 60.0);

        // The endless curve's move-speed escalation (DESIGN.md §1 Phase D) is
        // baked in at spawn, exactly as the health curve is: below 20:00 the
        // multiplier is 1.0, so a standard run is unaffected, and past it the
        // horde that keeps respawning gets faster instead of the escalation
        // being defined and never applied.
        var opts = enemy.Pool.SpawnOpts{
            .hp_mult = hp_mult,
            .speed_mult = enemy.speedMultiplier(t),
        };
        var elite_mask: u8 = 0;
        if (self.rng.unit() < enemy.eliteChance(t)) {
            // One modifier per elite, drawn uniformly from the four.
            elite_mask = switch (self.rng.below(4)) {
                0 => enemy.elite.vampiric,
                1 => enemy.elite.splitter,
                2 => enemy.elite.shielded,
                else => enemy.elite.haste_aura,
            };
            opts.elite_mask = elite_mask;
            opts.hp_mult *= enemy.elite.hp_mult;
            opts.radius_mult = enemy.elite.radius_mult;
            if (elite_mask & enemy.elite.vampiric != 0) {
                opts.speed_mult *= enemy.elite.vampiric_speed_mult;
            }
        }

        const i = self.enemies.spawnWith(archetype, pos, opts) orelse return;

        // Shielded: a barrier of 50% max HP, regenerated after 3.0 s without
        // damage (DESIGN.md §4).
        if (elite_mask & enemy.elite.shielded != 0) {
            self.enemies.barrier[i] = enemy.elite.shield_barrier * self.enemies.max_hp[i];
        }
    }

    /// Place a boss at `pos` (DESIGN.md §4): `2500 x M_HP(t) x (1 + 0.75(P-1))`
    /// HP, 100% knockback and freeze immunity.
    fn spawnBoss(self: *Simulation, pos: [2]f32, hp_mult: f32, players: u8) void {
        const t = @as(f32, @floatFromInt(self.tick)) /
            (@as(f32, @floatFromInt(root.tick_hz)) * 60.0);
        const party = 1.0 + enemy.boss.party_hp_step * (@as(f32, @floatFromInt(players)) - 1.0);
        const i = self.enemies.spawnWith(.boss, pos, .{
            .hp_mult = hp_mult * party,
            // A boss is an enemy too, so the endless move-speed escalation
            // reaches it the same way it reaches the horde.
            .speed_mult = enemy.speedMultiplier(t),
            .knockback_resist = 1.0,
            .status_immune = true,
        }) orelse return;
        // First attack one interval after the spawn.
        self.enemies.ai_timer[i] = enemy.boss.attack_interval_ticks;
    }

    /// Last applied input sequence per player slot, for `acked_seq`.
    pub fn ackedSeq(self: *const Simulation) [root.max_players]u32 {
        var out: [root.max_players]u32 = std.mem.zeroes([root.max_players]u32);
        for (&self.players, 0..) |p, i| {
            out[i] = if (p.active) p.last_input_seq else 0;
        }
        return out;
    }

    pub fn activePlayerCount(self: *const Simulation) u8 {
        var n: u8 = 0;
        for (&self.players) |p| {
            if (p.active) n += 1;
        }
        return n;
    }

    /// Players still alive, which is what ends a run.
    pub fn alivePlayerCount(self: *const Simulation) u8 {
        var n: u8 = 0;
        for (&self.players) |p| {
            if (p.active and p.flags.alive) n += 1;
        }
        return n;
    }

    /// Quantized wire form of one player (PROTOCOL.md "PlayerNet", 8 bytes).
    pub fn playerNet(p: *const PlayerState) wire.PlayerNet {
        return .{
            .player_id = p.id,
            .state_flags = StateFlags.byte(p.flags),
            .pos_x = wire.quantize(p.pos[0]),
            .pos_y = wire.quantize(p.pos[1]),
            .vel_angle = wire.angleToByte(
                std.math.atan2(@as(f32, p.vel[1]), @as(f32, p.vel[0])),
            ),
            .hp_pct = hpPercent(p.hp, p.max_hp),
        };
    }

    /// Quantized wire form of one enemy (PROTOCOL.md "EnemyNet", 12 bytes).
    pub fn enemyNet(pool: *const enemy.Pool, i: usize) wire.EnemyNet {
        const pos = pool.pos[i];
        const facing = pool.facing[i];
        // A Shielded elite's barrier is reported as part of its HP, so the
        // client's health bar reflects the total damage the enemy can still
        // absorb. Capped at 100% because `hp_pct` is a percentage.
        const hp = pool.hp[i] + pool.barrier[i];
        return .{
            .id = pool.id[i],
            .archetype = pool.archetype[i],
            .elite_mask = pool.elite_mask[i],
            .pos_x = wire.quantize(pos[0]),
            .pos_y = wire.quantize(pos[1]),
            .vel_angle = wire.angleToByte(std.math.atan2(facing[1], facing[0])),
            .hp_pct = hpPercent(hp, pool.max_hp[i]),
        };
    }

    /// Quantized wire form of one projectile (PROTOCOL.md "ProjNet", 12 bytes).
    pub fn projNet(pool: *const combat.ProjectilePool, i: usize) wire.ProjNet {
        const pos = pool.pos[i];
        const vel = pool.vel[i];
        return .{
            .id = pool.id[i],
            .owner_id = pool.owner_id[i],
            .weapon_id = pool.weapon_id[i],
            .shape = pool.shape[i],
            .pos_x = wire.quantize(pos[0]),
            .pos_y = wire.quantize(pos[1]),
            .vel_angle = wire.angleToByte(std.math.atan2(vel[1], vel[0])),
        };
    }

    /// Quantized wire form of one gem (PROTOCOL.md "GemNet", 12 bytes).
    pub fn gemNet(pool: *const gem.Pool, i: usize) wire.GemNet {
        return .{
            .id = pool.id[i],
            .pos_x = wire.quantize(pool.pos[i][0]),
            .pos_y = wire.quantize(pool.pos[i][1]),
            .xp_value = pool.xp_value[i],
            .magnet_target_id = pool.magnet_target[i],
            .reserved = 0,
        };
    }

    /// HP as a whole percentage, the form `hp_pct` carries on the wire.
    pub fn hpPercent(hp: f32, max_hp: f32) u8 {
        if (max_hp <= 0.0) return 0;
        return @intFromFloat(std.math.clamp(std.math.round(hp / max_hp * 100.0), 0.0, 100.0));
    }

    /// Snapshot payload contents. Every array borrows scratch space on this
    /// `Simulation`, so the view is only valid until the next call.
    pub fn snapshotView(self: *Simulation) wire.SnapshotView {
        var np: usize = 0;
        for (&self.players) |*p| {
            if (!p.active) continue;
            self.net_scratch[np] = playerNet(p);
            np += 1;
        }

        var ne: usize = 0;
        while (ne < self.enemies.count) : (ne += 1) {
            self.net_enemies[ne] = enemyNet(&self.enemies, ne);
        }

        var nk: usize = 0;
        while (nk < self.projectiles.count) : (nk += 1) {
            self.net_projs[nk] = projNet(&self.projectiles, nk);
        }

        var ng: usize = 0;
        while (ng < self.gems.count) : (ng += 1) {
            self.net_gems[ng] = gemNet(&self.gems, ng);
        }

        return .{
            .server_tick = self.tick,
            // Full snapshots carry no baseline; delta snapshots set this in
            // phase 4.
            .baseline_tick = 0,
            .run_time_ms = self.runTimeMs(),
            .acked_seq = self.ackedSeq(),
            .game_state = @intFromEnum(self.state),
            .counts = .{
                @intCast(np),
                @intCast(ne),
                @intCast(nk),
                @intCast(ng),
            },
            .players = self.net_scratch[0..np],
            .enemies = self.net_enemies[0..ne],
            .projs = self.net_projs[0..nk],
            .gems = self.net_gems[0..ng],
        };
    }

    /// Interest-filtered snapshot contents: only the entities within `radius`
    /// of `centre`, which is what a snapshot — full or delta — actually carries
    /// (PROTOCOL.md "Interest management"). The receiver's neighbourhood, not
    /// the whole arena.
    pub fn snapshotViewFor(self: *Simulation, centre: [2]f32, radius: f32) wire.SnapshotView {
        const r2 = radius * radius;

        var np: usize = 0;
        for (&self.players) |*p| {
            if (!p.active) continue;
            if (!inRadius(p.pos, centre, r2)) continue;
            self.net_scratch[np] = playerNet(p);
            np += 1;
        }

        var ne: usize = 0;
        for (0..self.enemies.count) |i| {
            if (!inRadius(self.enemies.pos[i], centre, r2)) continue;
            self.net_enemies[ne] = enemyNet(&self.enemies, i);
            ne += 1;
        }

        var nk: usize = 0;
        for (0..self.projectiles.count) |k| {
            if (!inRadius(self.projectiles.pos[k], centre, r2)) continue;
            self.net_projs[nk] = projNet(&self.projectiles, k);
            nk += 1;
        }

        var ng: usize = 0;
        for (0..self.gems.count) |k| {
            if (!inRadius(self.gems.pos[k], centre, r2)) continue;
            self.net_gems[ng] = gemNet(&self.gems, k);
            ng += 1;
        }

        return .{
            .server_tick = self.tick,
            .baseline_tick = 0,
            .run_time_ms = self.runTimeMs(),
            .acked_seq = self.ackedSeq(),
            .game_state = @intFromEnum(self.state),
            .counts = .{
                @intCast(np),
                @intCast(ne),
                @intCast(nk),
                @intCast(ng),
            },
            .players = self.net_scratch[0..np],
            .enemies = self.net_enemies[0..ne],
            .projs = self.net_projs[0..nk],
            .gems = self.net_gems[0..ng],
        };
    }
};

test "integrator moves a player at 12 units per second" {
    var sim = Simulation.init();
    const player = sim.spawnPlayer(0).?;

    const input = wire.Input{
        .input_seq = 1,
        .client_tick = 1,
        .move_x = 100,
        .move_y = 0,
        .aim_angle = 0,
        .buttons = 0,
    };
    sim.applyInput(0, input);

    var i: usize = 0;
    while (i < 60) : (i += 1) sim.advance();

    // 12.0 u/s for 1 second is 12.0 units; quantization drift is not present
    // here, so only float accumulation error is allowed.
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), player.pos[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), player.pos[1], 0.000001);
}

test "integrator advances at most 0.2 units per tick" {
    var sim = Simulation.init();
    const player = sim.spawnPlayer(0).?;
    sim.applyInput(0, .{ .input_seq = 1, .move_x = 100, .move_y = 100 });

    const before = player.pos;
    sim.advance();
    const dx = player.pos[0] - before[0];
    const dy = player.pos[1] - before[1];
    try std.testing.expect(dx <= 0.2 and dy <= 0.2);
    // The diagonal is normalized, so each axis covers 12 u/s / 60 * 0.7071.
    try std.testing.expectApproxEqAbs(@as(f32, 0.14142136), dx, 0.0001);
}

test "diagonal input is not faster than axis input" {
    var sim = Simulation.init();
    const straight = sim.spawnPlayer(0).?;
    sim.applyInput(0, .{ .input_seq = 1, .move_x = 100, .move_y = 0 });

    var sim2 = Simulation.init();
    const diagonal = sim2.spawnPlayer(0).?;
    sim2.applyInput(0, .{ .input_seq = 1, .move_x = 100, .move_y = 100 });

    var i: usize = 0;
    while (i < 60) : (i += 1) {
        sim.advance();
        sim2.advance();
    }
    // Both inputs cover 12 units per second of travel; only the direction differs.
    const straight_travel = std.math.hypot(straight.pos[0], straight.pos[1]);
    const diagonal_travel = std.math.hypot(diagonal.pos[0], diagonal.pos[1]);
    try std.testing.expectApproxEqAbs(straight_travel, diagonal_travel, 0.001);
}

test "integrator clamps to the arena walls" {
    var sim = Simulation.init();
    const player = sim.spawnPlayer(0).?;
    sim.applyInput(0, .{ .input_seq = 1, .move_x = 100, .move_y = 0 });

    var i: usize = 0;
    // 999.5 units at 12 u/s needs ~84 s == ~5000 ticks.
    while (i < 6000) : (i += 1) sim.advance();

    const limit = root.arena_half_size - root.player_half_extent;
    try std.testing.expect(player.pos[0] <= limit);
    try std.testing.expect(player.pos[0] >= -limit);
    try std.testing.expect(player.pos[1] <= limit);
    try std.testing.expect(player.pos[1] >= -limit);
    try std.testing.expectApproxEqAbs(limit, player.pos[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), player.pos[1], 0.000001);
}

test "a stationary player stays put" {
    var sim = Simulation.init();
    const player = sim.spawnPlayer(0).?;
    var i: usize = 0;
    while (i < 120) : (i += 1) sim.advance();
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), player.pos[0], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), player.pos[1], 0.000001);
}

test "acked_seq reports the newest applied input and nothing else" {
    var sim = Simulation.init();
    _ = sim.spawnPlayer(0).?;

    const acked = sim.ackedSeq();
    try std.testing.expectEqualSlices(u32, &[_]u32{ 0, 0, 0, 0 }, &acked);

    sim.applyInput(0, .{ .input_seq = 5, .move_x = 100 });
    try std.testing.expectEqual(@as(u32, 5), sim.ackedSeq()[0]);

    // Duplicates and out-of-order sequences are ignored.
    sim.applyInput(0, .{ .input_seq = 5, .move_x = 0 });
    sim.applyInput(0, .{ .input_seq = 3, .move_x = 0 });
    try std.testing.expectEqual(@as(u32, 5), sim.ackedSeq()[0]);

    sim.applyInput(0, .{ .input_seq = 6, .move_x = 0 });
    try std.testing.expectEqual(@as(u32, 6), sim.ackedSeq()[0]);
    // Player slots that never joined stay at zero.
    try std.testing.expectEqual(@as(u32, 0), sim.ackedSeq()[1]);
}

test "spawn refuses to hand out more than max_players slots" {
    var sim = Simulation.init();
    try std.testing.expect(sim.spawnPlayer(0) != null);
    try std.testing.expect(sim.spawnPlayer(0) != null);
    try std.testing.expect(sim.spawnPlayer(0) != null);
    try std.testing.expect(sim.spawnPlayer(0) != null);
    try std.testing.expect(sim.spawnPlayer(0) == null);
    try std.testing.expectEqual(@as(u8, 4), sim.activePlayerCount());

    // An explicit slot is honoured and double-booked only once.
    var sim2 = Simulation.init();
    try std.testing.expect(sim2.spawnPlayer(2) != null);
    try std.testing.expect(sim2.spawnPlayer(2) == null);
    try std.testing.expectEqual(@as(u8, 1), sim2.activePlayerCount());
    try std.testing.expect(sim2.spawnPlayer(9) == null);

    sim.despawnPlayer(0);
    try std.testing.expect(sim.spawnPlayer(0) != null);
}

test "run_time_ms is derived from the tick counter" {
    var sim = Simulation.init();
    try std.testing.expectEqual(@as(u32, 0), sim.runTimeMs());
    var i: usize = 0;
    while (i < 30) : (i += 1) sim.advance();
    try std.testing.expectEqual(@as(u32, 500), sim.runTimeMs());
}

test "snapshot view quantizes positions and reports acked sequences" {
    var sim = Simulation.init();
    const player = sim.spawnPlayer(0).?;
    _ = player;
    sim.applyInput(0, .{ .input_seq = 7, .move_x = 100, .move_y = -100 });
    sim.advance();

    const view = sim.snapshotView();
    try std.testing.expectEqual(@as(usize, 1), view.players.len);
    try std.testing.expectEqual(@as(u32, 1), view.server_tick);
    try std.testing.expectEqual(@as(u32, 0), view.baseline_tick);
    try std.testing.expectEqual(@as(u32, 16), view.run_time_ms);
    try std.testing.expectEqual(@as(u32, 7), view.acked_seq[0]);
    try std.testing.expectEqual(@as(u16, 1), view.counts[0]);
    try std.testing.expectEqual(@as(u16, 0), view.counts[1]);

    // Diagonal input is normalized, so each axis covers 0.7071 of a 0.2 step.
    const step: f32 = root.move_speed / root.tick_hz * 0.70710678118654752;
    try std.testing.expectEqualSlices(i16, &.{ wire.quantize(step), wire.quantize(-step) },
        &.{ view.players[0].pos_x, view.players[0].pos_y });
    try std.testing.expectEqual(@as(u8, 0), view.players[0].player_id);
    try std.testing.expectEqual(@as(u8, 1), view.players[0].state_flags);
    try std.testing.expectEqual(@as(u8, 100), view.players[0].hp_pct);
}

test "simulation is deterministic for a fixed input script" {
    var a = Simulation.init();
    const pa = a.spawnPlayer(0).?;
    var b = Simulation.init();
    const pb = b.spawnPlayer(0).?;

    var seq: u32 = 1;
    var i: usize = 0;
    while (i < 600) : (i += 1) {
        // Alternate direction every 30 ticks.
        const move_x: i8 = if (@mod(i / 30, 2) == 0) 100 else -100;
        a.applyInput(0, .{ .input_seq = seq, .move_x = move_x, .move_y = 10 });
        b.applyInput(0, .{ .input_seq = seq, .move_x = move_x, .move_y = 10 });
        seq += 1;
        a.advance();
        b.advance();
    }

    try std.testing.expectEqual(pa.pos[0], pb.pos[0]);
    try std.testing.expectEqual(pa.pos[1], pb.pos[1]);
    try std.testing.expectEqual(pa.vel[0], pb.vel[0]);
    try std.testing.expectEqual(pa.last_input_seq, pb.last_input_seq);
}

// ---------------------------------------------------------------------------
// Phase 2 — combat
// ---------------------------------------------------------------------------

/// Strip a player's weapons, so a test can watch enemy AI without the player's
/// own four weapons killing the subject. `0xff` names no weapon, so the slot is
/// simply never ready.
fn disarm(p: *PlayerState) void {
    for (&p.weapons) |*slot| {
        slot.id = 0xff;
        slot.cooldown_ticks = 0;
    }
}

test "a joining player carries all four weapons at level 1" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    try std.testing.expectEqual(root.max_weapons, p.weapons.len);
    for (&p.weapons, 0..) |slot, i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), slot.id);
        try std.testing.expectEqual(@as(u8, 1), slot.level);
        try std.testing.expectEqual(@as(u16, 0), slot.cooldown_ticks);
        try std.testing.expect(!slot.evolved);
        try std.testing.expect(slot.spec() != null);
    }

    // A respawned slot is re-equipped rather than inheriting the old cooldowns.
    p.weapons[0].cooldown_ticks = 40;
    sim.despawnPlayer(0);
    const again = sim.spawnPlayer(0).?;
    try std.testing.expectEqual(@as(u16, 0), again.weapons[0].cooldown_ticks);
}

test "a swarmer pursues the nearest player at 4.5 units per second" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);
    const e = sim.enemies.spawn(.circle_t1, .{ 20.0, 0.0 }).?;

    var i: usize = 0;
    while (i < 60) : (i += 1) sim.advance();

    // One second at 4.5 u/s, straight at the player.
    try std.testing.expectApproxEqAbs(@as(f32, 15.5), sim.enemies.pos[e][0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), sim.enemies.pos[e][1], 1e-4);
    // The velocity the client is told about points along the pursuit.
    try std.testing.expect(sim.enemies.vel[e][0] < 0.0);
}

test "the darter pauses 0.4 s at 10 units and then lunges at 15 u/s" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);
    const e = sim.enemies.spawn(.triangle_t1, .{ 10.0, 0.0 }).?;

    // The pause: 24 ticks standing still.
    var i: usize = 0;
    while (i < 24) : (i += 1) {
        sim.advance();
        try std.testing.expectApproxEqAbs(@as(f32, 10.0), sim.enemies.pos[e][0], 1e-5);
    }
    try std.testing.expectEqual(
        @as(u8, @intFromEnum(enemy.AiState.windup)),
        sim.enemies.ai_state[e],
    );

    // Then the lunge, 15 u/s for 0.5 s: 7.5 units covered.
    sim.advance();
    try std.testing.expectApproxEqAbs(@as(f32, 9.75), sim.enemies.pos[e][0], 1e-5);
    try std.testing.expectEqual(
        @as(u8, @intFromEnum(enemy.AiState.lunge)),
        sim.enemies.ai_state[e],
    );
    i = 0;
    while (i < 29) : (i += 1) sim.advance();
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), sim.enemies.pos[e][0], 1e-4);

    // And back to pursuit, slower than the lunge.
    sim.advance();
    try std.testing.expectEqual(
        @as(u8, @intFromEnum(enemy.AiState.pursue)),
        sim.enemies.ai_state[e],
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 7.0),
        std.math.hypot(sim.enemies.vel[e][0], sim.enemies.vel[e][1]),
        1e-4,
    );
}

test "contact damage hurts the player and can kill them" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);
    try std.testing.expectEqual(@as(f32, 100.0), p.hp);

    // A swarmer sitting on top of the player: 5 damage, twice a second.
    _ = sim.enemies.spawn(.circle_t1, .{ 0.6, 0.0 }).?;

    sim.advance();
    try std.testing.expectApproxEqAbs(@as(f32, 95.0), p.hp, 1e-4);

    // Held on cooldown for the next 29 ticks.
    var i: usize = 0;
    while (i < 29) : (i += 1) sim.advance();
    try std.testing.expectApproxEqAbs(@as(f32, 95.0), p.hp, 1e-4);
    sim.advance();
    try std.testing.expectApproxEqAbs(@as(f32, 90.0), p.hp, 1e-4);

    // Unlike phase 2, HP now reaches zero and the run ends.
    i = 0;
    while (i < 3000) : (i += 1) sim.advance();
    try std.testing.expect(p.hp <= 0.0);
    try std.testing.expect(!p.flags.alive);
    try std.testing.expectEqual(GameState.game_over, sim.state);
    try std.testing.expect(sim.game_over_pending);
}

test "contact damage needs an actual overlap" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);
    // 1.2 units out: its 0.5 radius does not yet reach the player's 0.5 box.
    _ = sim.enemies.spawn(.circle_t1, .{ 1.2, 0.0 }).?;

    sim.advance();
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), p.hp, 1e-4);

    // It closes at 4.5 u/s and lands its first hit a couple of ticks later.
    sim.advance();
    sim.advance();
    try std.testing.expect(p.hp < 100.0);
}

test "the spawn wave places enemies in the 48 to 56 unit ring" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);
    p.pos = .{ 0.0, 0.0 };

    // Nothing spawns before the first evaluation.
    var i: usize = 0;
    while (i < enemy.spawn_interval_ticks - 1) : (i += 1) sim.advance();
    try std.testing.expectEqual(@as(usize, 0), sim.enemies.count);

    sim.advance();
    try std.testing.expectEqual(@as(u32, enemy.spawn_interval_ticks), sim.tick);
    try std.testing.expect(sim.enemies.count > 0);
    for (0..sim.enemies.count) |e| {
        const d = std.math.hypot(sim.enemies.pos[e][0], sim.enemies.pos[e][1]);
        try std.testing.expect(d >= enemy.spawn_min_radius - 0.01);
        try std.testing.expect(d <= enemy.spawn_max_radius + 0.01);
        try std.testing.expectEqual(
            @as(u8, @intFromEnum(enemy.Archetype.circle_t1)),
            sim.enemies.archetype[e],
        );
    }
}

test "the spawn wave follows the players' centroid" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);
    p.pos = .{ 400.0, -300.0 };

    var i: usize = 0;
    while (i < enemy.spawn_interval_ticks) : (i += 1) sim.advance();

    try std.testing.expect(sim.enemies.count > 0);
    for (0..sim.enemies.count) |e| {
        const d = std.math.hypot(
            sim.enemies.pos[e][0] - 400.0,
            sim.enemies.pos[e][1] + 300.0,
        );
        try std.testing.expect(d >= enemy.spawn_min_radius - 0.01);
        try std.testing.expect(d <= enemy.spawn_max_radius + 0.01);
    }
}

test "placeFrom keeps the ring's radius and stays inside the arena" {
    const limit = root.arena_half_size - enemy.max_radius;
    // The last two are the corners: the ring is wider than the room left there.
    const centres = [_][2]f32{
        .{ limit, 0.0 },
        .{ 0.0, limit },
        .{ limit, limit },
        .{ -limit, limit },
        .{ 0.0, 0.0 },
    };
    for (centres) |c| {
        var i: usize = 0;
        while (i < 200) : (i += 1) {
            const angle = @as(f32, @floatFromInt(i)) * (2.0 * std.math.pi / 200.0);
            const dist = enemy.spawn_min_radius +
                (@as(f32, @floatFromInt(i % 17)) / 17.0) *
                (enemy.spawn_max_radius - enemy.spawn_min_radius);
            const p = Simulation.placeFrom(c, angle, dist);
            // The distance from the centre is exactly what was asked for, so the
            // ring's inner radius holds even against a wall.
            const d = std.math.hypot(p[0] - c[0], p[1] - c[1]);
            try std.testing.expectApproxEqAbs(dist, d, 1e-4);
            // ... and the body still fits inside the arena.
            try std.testing.expect(@abs(p[0]) <= limit);
            try std.testing.expect(@abs(p[1]) <= limit);
        }
    }
}

test "a wave spawned against the arena wall keeps its 48 unit inner radius" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);
    // Hard against the +x wall, where clamping each enemy to the wall would
    // pull it inside the ring.
    p.pos = .{ root.arena_half_size - enemy.max_radius - 1.0, 0.0 };

    var i: usize = 0;
    while (i < enemy.spawn_interval_ticks - 1) : (i += 1) sim.advance();
    sim.advance();

    try std.testing.expect(sim.enemies.count > 0);
    for (0..sim.enemies.count) |e| {
        const d = std.math.hypot(
            sim.enemies.pos[e][0] - p.pos[0],
            sim.enemies.pos[e][1] - p.pos[1],
        );
        try std.testing.expect(d >= enemy.spawn_min_radius - 0.01);
        try std.testing.expect(d <= enemy.spawn_max_radius + 0.01);
    }
}

test "enemies owed to a full active cap are placed by a later wave" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);
    p.pos = .{ 0.0, 0.0 };

    // Fill the pool to the cap at t = 10 s, however many waves that takes.
    sim.tick = 600;
    var i: usize = 0;
    while (i < 200) : (i += 1) sim.spawnWave();
    const cap = enemy.activeCap(600.0 / 3600.0);
    try std.testing.expectEqual(cap, sim.enemies.count);

    // The pool is full, so every wave's whole output is owed, not discarded.
    sim.spawnWave();
    try std.testing.expectEqual(cap, sim.enemies.count);
    const banked = sim.spawn_debt;
    try std.testing.expect(banked > 0);

    // Emptying the pool makes the whole bank payable at once, so the next wave
    // refills the pool to the cap. Without the bank it would place only its own
    // handful of enemies and leave the pool nearly empty.
    for (0..sim.enemies.count) |k| sim.enemies.hp[k] = 0.0;
    _ = sim.enemies.reapDead();
    try std.testing.expectEqual(@as(usize, 0), sim.enemies.count);

    sim.spawnWave();
    try std.testing.expectEqual(cap, sim.enemies.count);
    try std.testing.expect(sim.spawn_debt < banked);
}

test "spawn debt past the pool size is still owed, not truncated" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);
    p.pos = .{ 0.0, 0.0 };

    // Late enough that a single wave owes far more than the pool can hold, and
    // the pool is then filled, so every following wave banks its whole output.
    sim.tick = 3600 * 60 * 40;
    var i: usize = 0;
    while (i < 400) : (i += 1) sim.spawnWave();
    try std.testing.expectEqual(root.max_enemies, sim.enemies.count);

    // Banked output has to keep accumulating past the pool size: a clamp there
    // would silently drop spawns in exactly the saturated, endlessly
    // escalating case the debt exists for.
    i = 0;
    while (i < 12) : (i += 1) sim.spawnWave();
    try std.testing.expect(sim.spawn_debt > root.max_enemies);
}

test "no spawn happens without a player, and the cap bounds the pool" {
    var sim = Simulation.init();
    sim.tick = 600;
    sim.spawnWave();
    try std.testing.expectEqual(@as(usize, 0), sim.enemies.count);

    const p = sim.spawnPlayer(0).?;
    disarm(p);
    // At t = 10 s the cap is 40, however many waves are evaluated.
    sim.tick = 600;
    var i: usize = 0;
    while (i < 200) : (i += 1) sim.spawnWave();
    try std.testing.expectEqual(enemy.activeCap(600.0 / 3600.0), sim.enemies.count);
}

test "the triangle archetype only spawns after 1:30" {
    // Before the unlock: every wave is circles.
    var before = Simulation.init();
    const pb = before.spawnPlayer(0).?;
    disarm(pb);
    before.tick = 89 * root.tick_hz;
    var i: usize = 0;
    while (i < 20) : (i += 1) before.spawnWave();
    try std.testing.expect(before.enemies.count > 0);
    for (0..before.enemies.count) |e| {
        try std.testing.expectEqual(
            @as(u8, @intFromEnum(enemy.Archetype.circle_t1)),
            before.enemies.archetype[e],
        );
    }

    // After it, both are in play. A fresh simulation, because the first one is
    // already sitting on the active cap for this point in the run.
    var after = Simulation.init();
    const pa = after.spawnPlayer(0).?;
    disarm(pa);
    after.tick = 90 * root.tick_hz;
    var circles: usize = 0;
    var triangles: usize = 0;
    i = 0;
    while (i < 20) : (i += 1) after.spawnWave();
    try std.testing.expect(after.enemies.count > 0);
    for (0..after.enemies.count) |e| {
        switch (@as(enemy.Archetype, @enumFromInt(after.enemies.archetype[e]))) {
            .circle_t1 => circles += 1,
            .triangle_t1 => triangles += 1,
            else => unreachable,
        }
    }
    try std.testing.expect(triangles > 0 and circles > 0);
}

test "a full enemy pool degrades instead of crashing" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);

    var i: usize = 0;
    while (i < root.max_enemies) : (i += 1) {
        try std.testing.expect(sim.enemies.spawn(.circle_t1, .{ 0.0, 0.0 }) != null);
    }
    try std.testing.expectEqual(root.max_enemies, sim.enemies.count);

    // Waves that cannot place anything must still leave the tick working, and
    // the simulation must keep running rather than growing past the cap.
    sim.tick = 60;
    i = 0;
    while (i < 30) : (i += 1) {
        sim.advance();
        try std.testing.expect(sim.enemies.count <= root.max_enemies);
    }

    // The broadphase covers only what it can hold, and still answers.
    try std.testing.expectEqual(spatial.SpatialHash.capacity, sim.grid.len);
}

test "a full projectile pool degrades instead of crashing" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    const gun = weapon.spec(@intFromEnum(weapon.Id.gun)).?;

    var i: usize = 0;
    while (i < root.max_projectiles) : (i += 1) {
        try std.testing.expect(sim.projectiles.spawn(p.id, gun, .{ 0.0, 0.0 }, .{ 1.0, 0.0 }) != null);
    }
    // One enemy next to the player, so all four weapons try to fire every tick.
    _ = sim.enemies.spawn(.circle_t1, .{ 1.0, 0.0 }).?;

    i = 0;
    while (i < 120) : (i += 1) {
        sim.advance();
        try std.testing.expect(sim.projectiles.count <= root.max_projectiles);
    }
}

test "all four weapons fire, and between them kill enemies" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;

    // A ring of swarmers just outside the sword's reach but inside the gun's.
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const a = @as(f32, @floatFromInt(i)) * (2.0 * std.math.pi / 12.0);
        _ = sim.enemies.spawn(.circle_t1, .{ @cos(a) * 2.0, @sin(a) * 2.0 }).?;
    }
    // One right on top, so the arc weapons have something to sweep.
    _ = sim.enemies.spawn(.circle_t1, .{ 1.0, 1.0 }).?;

    // Every weapon fires on the first tick, because the cooldowns start at zero.
    sim.advance();
    var seen: [4]bool = @splat(false);
    for (0..sim.projectiles.count) |k| {
        const id = sim.projectiles.weapon_id[k];
        if (id < 4) seen[id] = true;
    }
    try std.testing.expect(seen[0] and seen[1] and seen[2] and seen[3]);

    i = 0;
    while (i < 600) : (i += 1) sim.advance();
    // Kills, not a shrinking pool: the spawn wave is adding enemies throughout.
    try std.testing.expect(sim.kills > 0);
    _ = p;
}

test "the sword kills what is in front of it and spares what is behind" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    // Sword only, so the other three cannot confound the result.
    for (&p.weapons, 0..) |*slot, i| {
        if (i != @intFromEnum(weapon.Id.sword)) slot.id = 0xff;
    }
    // The front one is strictly nearer, so it is unambiguously the auto-aim
    // target and the swing goes along +x.
    const front = sim.enemies.spawn(.circle_t1, .{ 1.5, 0.0 }).?;
    const back = sim.enemies.spawn(.circle_t1, .{ -2.0, 0.0 }).?;
    // Give the front one enough HP to survive, so the exact damage is visible
    // rather than inferred from a death.
    sim.enemies.hp[front] = 100.0;
    sim.enemies.max_hp[front] = 100.0;

    sim.advance();

    // Exactly one 20 damage sword hit landed, on the enemy in front.
    try std.testing.expectApproxEqAbs(@as(f32, 80.0), sim.enemies.hp[front], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), sim.enemies.hp[back], 1e-4);
    try std.testing.expectEqual(@as(u32, 0), sim.kills);
    // The one that survived still has its HP on the wire as a percentage.
    try std.testing.expectEqual(@as(u8, 80), Simulation.hpPercent(sim.enemies.hp[front], sim.enemies.max_hp[front]));
    try std.testing.expectEqual(@as(u8, 100), Simulation.hpPercent(sim.enemies.hp[back], sim.enemies.max_hp[back]));
}

test "weapons auto-aim at the nearest enemy without any input" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);
    p.weapons[@intFromEnum(weapon.Id.gun)].id = @intFromEnum(weapon.Id.gun);
    p.weapons[@intFromEnum(weapon.Id.gun)].cooldown_ticks = 0;

    _ = sim.enemies.spawn(.circle_t1, .{ 0.0, 8.0 }).?;
    _ = sim.enemies.spawn(.circle_t1, .{ 0.0, 3.0 }).?;

    sim.advance();
    try std.testing.expectEqual(@as(usize, 1), sim.projectiles.count);
    // Fired along +y, at the closer of the two.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), sim.projectiles.vel[0][0], 1e-5);
    try std.testing.expect(sim.projectiles.vel[0][1] > 0.0);
}

test "knockback pushes an enemy away from the hit and decays" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);
    p.weapons[0].id = @intFromEnum(weapon.Id.sword);
    p.weapons[0].cooldown_ticks = 0;

    // A swarmer with enough HP to survive the 20 damage sword hit.
    const e = sim.enemies.spawn(.circle_t1, .{ 1.5, 0.0 }).?;
    sim.enemies.hp[e] = 500.0;
    sim.enemies.max_hp[e] = 500.0;

    sim.advance();
    // Pushed outward along the hit direction, not towards the player.
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), sim.enemies.kb[e][0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), sim.enemies.kb[e][1], 1e-5);

    // Disarm, so the decay is measured without the next swing re-applying it.
    p.weapons[0].id = 0xff;

    // It decays to nothing within about a second and a half.
    var i: usize = 0;
    while (i < 100) : (i += 1) sim.advance();
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), sim.enemies.kb[e][0], 1e-9);
    // The enemy is alive and back on the player's doorstep.
    try std.testing.expect(sim.enemies.hp[e] > 0.0);
}

test "the snapshot carries the enemy, projectile and gem arrays" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    _ = p;

    const e0 = sim.enemies.spawn(.circle_t1, .{ 3.0, -4.0 }).?;
    const e1 = sim.enemies.spawn(.triangle_t1, .{ -7.0, 2.0 }).?;
    sim.enemies.hp[e1] = 5.0;
    const gun = weapon.spec(@intFromEnum(weapon.Id.gun)).?;
    try std.testing.expect(sim.projectiles.spawn(0, gun, .{ 1.0, 1.0 }, .{1.0, 0.0}) != null);
    _ = sim.gems.spawn(.{ 2.0, 2.0 }, gem.small_xp).?;

    const view = sim.snapshotView();
    try std.testing.expectEqual(@as(u16, 1), view.counts[0]);
    try std.testing.expectEqual(@as(u16, 2), view.counts[1]);
    try std.testing.expectEqual(@as(u16, 1), view.counts[2]);
    try std.testing.expectEqual(@as(u16, 1), view.counts[3]);
    try std.testing.expectEqual(@as(usize, 2), view.enemies.len);
    try std.testing.expectEqual(@as(usize, 1), view.projs.len);
    try std.testing.expectEqual(@as(usize, 1), view.gems.len);

    try std.testing.expectEqual(sim.enemies.id[e0], view.enemies[0].id);
    try std.testing.expectEqual(@intFromEnum(enemy.Archetype.circle_t1), view.enemies[0].archetype);
    try std.testing.expectEqual(@as(u8, 0), view.enemies[0].elite_mask);
    try std.testing.expectEqual(wire.quantize(3.0), view.enemies[0].pos_x);
    try std.testing.expectEqual(wire.quantize(-4.0), view.enemies[0].pos_y);
    try std.testing.expectEqual(@as(u8, 100), view.enemies[0].hp_pct);
    // 5 of 10 HP.
    try std.testing.expectEqual(@as(u8, 50), view.enemies[1].hp_pct);
    try std.testing.expectEqual(@intFromEnum(enemy.Archetype.triangle_t1), view.enemies[1].archetype);

    try std.testing.expectEqual(@as(u8, 0), view.projs[0].owner_id);
    try std.testing.expectEqual(@intFromEnum(weapon.Id.gun), view.projs[0].weapon_id);
    try std.testing.expectEqual(@intFromEnum(wire.ProjShape.circle), view.projs[0].shape);
    try std.testing.expectEqual(wire.quantize(1.0), view.projs[0].pos_x);

    // The gem carries its value and its stationary magnet state.
    try std.testing.expectEqual(@as(u16, gem.small_xp), view.gems[0].xp_value);
    try std.testing.expectEqual(gem.no_magnet, view.gems[0].magnet_target_id);
    try std.testing.expectEqual(wire.quantize(2.0), view.gems[0].pos_x);

    // The wire layout is header, then players, enemies, projectiles, gems.
    const frame = try wire.encodeSnapshotFull(std.testing.allocator, view);
    defer std.testing.allocator.free(frame);
    try std.testing.expectEqual(
        @as(usize, wire.header_size + wire.snapshot_header_wire_size +
            8 * 1 + 12 * 2 + 12 * 1 + 12 * 1),
        frame.len,
    );
}

test "the whole combat simulation is deterministic" {
    var a = Simulation.init();
    const pa = a.spawnPlayer(0).?;
    var b = Simulation.init();
    const pb = b.spawnPlayer(0).?;
    pa.pos = .{ 30.0, -20.0 };
    pb.pos = .{ 30.0, -20.0 };

    var i: usize = 0;
    while (i < 900) : (i += 1) {
        const move_x: i8 = if (@mod(i / 45, 2) == 0) 100 else -37;
        a.applyInput(0, .{ .input_seq = @intCast(i + 1), .move_x = move_x, .move_y = -20 });
        b.applyInput(0, .{ .input_seq = @intCast(i + 1), .move_x = move_x, .move_y = -20 });
        a.advance();
        b.advance();
    }

    // Past the 1:30 triangle unlock, so both archetypes are in play.
    try std.testing.expect(a.enemies.count > 0);
    try std.testing.expectEqual(a.enemies.count, b.enemies.count);
    try std.testing.expectEqual(a.projectiles.count, b.projectiles.count);
    try std.testing.expectEqual(a.kills, b.kills);
    try std.testing.expectEqual(pa.hp, pb.hp);
    try std.testing.expectEqual(pa.pos[0], pb.pos[0]);

    for (0..a.enemies.count) |e| {
        try std.testing.expectEqual(a.enemies.id[e], b.enemies.id[e]);
        try std.testing.expectEqual(a.enemies.archetype[e], b.enemies.archetype[e]);
        try std.testing.expectEqual(a.enemies.pos[e][0], b.enemies.pos[e][0]);
        try std.testing.expectEqual(a.enemies.pos[e][1], b.enemies.pos[e][1]);
        try std.testing.expectEqual(a.enemies.hp[e], b.enemies.hp[e]);
    }
    for (0..a.projectiles.count) |k| {
        try std.testing.expectEqual(a.projectiles.id[k], b.projectiles.id[k]);
        try std.testing.expectEqual(a.projectiles.pos[k][0], b.projectiles.pos[k][0]);
    }
}

test "the stress load holds exactly the requested counts on the wire" {
    // The phase-2 definition of done is observed through a client, so the counts
    // a snapshot reports have to be the counts that were asked for — not merely
    // close to them. The player is left armed: enemies die and are reaped every
    // tick, and the load is still what the next snapshot advertises.
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    _ = p;
    sim.stress = .{ .enemies = 1000, .projectiles = 500 };

    var i: usize = 0;
    while (i < 120) : (i += 1) {
        sim.advance();
        const view = sim.snapshotView();
        try std.testing.expectEqual(@as(u16, 1000), view.counts[1]);
        try std.testing.expectEqual(@as(u16, 500), view.counts[2]);
        try std.testing.expectEqual(@as(usize, 1000), sim.enemies.count);
        try std.testing.expectEqual(@as(usize, 500), sim.projectiles.count);
    }
}

test "the stress load holds the world at a fixed size" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);
    // The stressed projectiles kill enemies, so gems drop and the player would
    // level up, and 500 enemies clustering on an unarmed player would kill it;
    // this test is about the load, not the level curve or the death rule, so
    // the bar is pinned out of reach and the player is invulnerable.
    p.xp_next = std.math.maxInt(u32);
    p.flags.invulnerable = true;
    sim.stress = .{ .enemies = 500, .projectiles = 200 };

    // Nothing to hold before a player exists: the load is placed around them.
    var empty = Simulation.init();
    empty.stress = .{ .enemies = 10, .projectiles = 10 };
    empty.advance();
    try std.testing.expectEqual(@as(usize, 0), empty.enemies.count);

    var i: usize = 0;
    while (i < 30) : (i += 1) {
        sim.advance();
        try std.testing.expectEqual(@as(usize, 500), sim.enemies.count);
        try std.testing.expectEqual(@as(usize, 200), sim.projectiles.count);
    }

    // Every stressed enemy is a swarmer inside the placement radius.
    for (0..sim.enemies.count) |e| {
        try std.testing.expectEqual(
            @as(u8, @intFromEnum(enemy.Archetype.circle_t1)),
            sim.enemies.archetype[e],
        );
        const d = std.math.hypot(sim.enemies.pos[e][0], sim.enemies.pos[e][1]);
        try std.testing.expect(d <= 36.0);
    }

    // Turning it off lets the world drain again.
    sim.stress = null;
    i = 0;
    while (i < 200) : (i += 1) sim.advance();
    try std.testing.expect(sim.enemies.count < 500);
}

test "a paused simulation advances nothing" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);
    _ = sim.enemies.spawn(.circle_t1, .{ 10.0, 0.0 }).?;
    sim.advance();
    const pos = sim.enemies.pos[0];
    const tick = sim.tick;

    sim.state = .level_up_pause;
    var i: usize = 0;
    while (i < 60) : (i += 1) sim.advance();
    try std.testing.expectEqual(pos, sim.enemies.pos[0]);
    try std.testing.expectEqual(tick, sim.tick);
}

// ---------------------------------------------------------------------------
// Phase 3 — the upgrade engine
// ---------------------------------------------------------------------------

test "a dead enemy drops a gem worth its archetype's XP" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);
    const e = sim.enemies.spawn(.circle_t1, .{ 5.0, 5.0 }).?;
    sim.enemies.hp[e] = 0.0;

    sim.advance();
    try std.testing.expectEqual(@as(usize, 1), sim.gems.count);
    try std.testing.expectEqual(@as(u16, gem.small_xp), sim.gems.xp_value[0]);
    try std.testing.expectEqual(gem.no_magnet, sim.gems.magnet_target[0]);
    // The corpse is compacted away.
    try std.testing.expectEqual(@as(usize, 0), sim.enemies.count);
    try std.testing.expectEqual(@as(u32, 1), sim.kills);
}

test "a gem is collected when the player walks onto it" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);
    p.pos = .{ 0.0, 0.0 };
    _ = sim.gems.spawn(.{ 1.0, 0.0 }, gem.small_xp).?;
    try std.testing.expectEqual(@as(u32, 0), p.xp);

    var i: usize = 0;
    while (i < 10) : (i += 1) sim.advance();
    // The gem is inside the 3.0 unit pickup radius, so it magnetized and flew
    // in, and the player collected it.
    try std.testing.expectEqual(@as(usize, 0), sim.gems.count);
    try std.testing.expect(p.xp >= gem.small_xp);
}

test "a gem outside the pickup radius stays put" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);
    p.pos = .{ 0.0, 0.0 };
    _ = sim.gems.spawn(.{ 20.0, 0.0 }, gem.small_xp).?;

    sim.advance();
    try std.testing.expectEqual(@as(usize, 1), sim.gems.count);
    try std.testing.expectEqual(gem.no_magnet, sim.gems.magnet_target[0]);
    try std.testing.expectEqual(@as(u32, 0), p.xp);
}

test "Magnet Array scales the pickup radius" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);
    p.pos = .{ 0.0, 0.0 };
    // Level 5 Magnet Array: 3.0 * 2.75 = 8.25 units.
    p.passives[6] = 5;
    _ = sim.gems.spawn(.{ 7.0, 0.0 }, gem.small_xp).?;

    var i: usize = 0;
    while (i < 40) : (i += 1) sim.advance();
    try std.testing.expectEqual(@as(usize, 0), sim.gems.count);
    try std.testing.expect(p.xp >= gem.small_xp);
}

test "a filled XP bar pauses the run and offers three choices" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);
    p.xp = p.xp_next;

    sim.advance();
    try std.testing.expectEqual(GameState.level_up_pause, sim.state);
    try std.testing.expectEqual(@as(usize, 1), sim.pending_count);
    try std.testing.expectEqual(@as(u16, 2), p.level);
    try std.testing.expect(!sim.pending_levelups[0].resolved);
    // The offer carries three distinct options.
    const opts = sim.pending_levelups[0].options;
    try std.testing.expect(opts[0].item_id != opts[1].item_id);
    try std.testing.expect(opts[1].item_id != opts[2].item_id);
    try std.testing.expect(opts[0].item_id != opts[2].item_id);
    // The simulation is paused: the tick does not advance while it waits.
    const tick = sim.tick;
    sim.advance();
    try std.testing.expectEqual(tick, sim.tick);
}

test "answering the offer applies the choice and resumes" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);
    p.xp = p.xp_next;
    sim.advance();

    const ev = sim.pending_levelups[0];
    const chosen = ev.options[0];
    try std.testing.expect(sim.submitChoice(0, ev.event_id, 0));

    // A passive choice lands in the passive array at level 1.
    if (chosen.item_id >= 16 and chosen.item_id < 26) {
        try std.testing.expectEqual(@as(u8, 1), p.passives[chosen.item_id - 16]);
    }
    try std.testing.expect(sim.loadout_dirty[0]);
    try std.testing.expectEqual(GameState.running, sim.state);
    try std.testing.expectEqual(@as(usize, 0), sim.pending_count);
}

test "a stale or repeated choice is ignored" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);
    p.xp = p.xp_next;
    sim.advance();
    const ev = sim.pending_levelups[0];

    try std.testing.expect(!sim.submitChoice(0, ev.event_id + 100, 0));
    try std.testing.expect(sim.submitChoice(0, ev.event_id, 0));
    // Already resolved.
    try std.testing.expect(!sim.submitChoice(0, ev.event_id, 1));
}

test "the 15 second timeout auto-selects option 0" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);
    p.xp = p.xp_next;
    sim.advance();
    const ev = sim.pending_levelups[0];

    var i: u32 = 0;
    while (i < levelup_timeout_ticks) : (i += 1) {
        sim.advance();
        if (sim.state == .running) break;
    }
    try std.testing.expectEqual(GameState.running, sim.state);
    // Option 0 was applied, and the offer was consumed.
    try std.testing.expectEqual(@as(usize, 0), sim.pending_count);
    _ = ev;
}

test "a level-8 weapon with its passive maxed evolves" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);
    p.weapons[0].id = upgrade.ids.sword;
    p.weapons[0].level = 8;
    p.passives[2] = 5; // Clockwork Gear

    // Offer until Vorpal Blender appears, then take it.
    var evolved = false;
    var attempts: usize = 0;
    while (attempts < 200 and !evolved) : (attempts += 1) {
        p.xp = p.xp_next;
        sim.advance();
        const ev = sim.pending_levelups[0];
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            if (ev.options[i].item_id == upgrade.ids.vorpal_blender) {
                try std.testing.expect(sim.submitChoice(0, ev.event_id, @intCast(i)));
                evolved = true;
                break;
            }
        }
        if (!evolved) {
            try std.testing.expect(sim.submitChoice(0, ev.event_id, 0));
        }
    }
    try std.testing.expect(evolved);
    try std.testing.expectEqual(upgrade.ids.vorpal_blender, p.weapons[0].id);
    try std.testing.expect(p.weapons[0].evolved);
    try std.testing.expectEqual(@as(u8, 8), p.weapons[0].level);
}

test "the weapon level table changes what a weapon does" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    // Sword only, level 1.
    for (&p.weapons, 0..) |*slot, i| {
        if (i != 0) slot.id = 0xff;
    }
    const front = sim.enemies.spawn(.circle_t1, .{ 1.5, 0.0 }).?;
    sim.enemies.hp[front] = 1000.0;
    sim.enemies.max_hp[front] = 1000.0;
    sim.advance();
    const after_l1 = sim.enemies.hp[front];

    // Level 8: 90 damage, plus a rear slash.
    p.weapons[0].level = 8;
    p.weapons[0].cooldown_ticks = 0;
    sim.enemies.hp[front] = 1000.0;
    sim.advance();
    const after_l8 = sim.enemies.hp[front];
    try std.testing.expect(after_l8 < after_l1 - 60.0);
}

test "passives change the simulation" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    // Sword only.
    for (&p.weapons, 0..) |*slot, i| {
        if (i != 0) slot.id = 0xff;
    }
    const front = sim.enemies.spawn(.circle_t1, .{ 1.5, 0.0 }).?;
    sim.enemies.hp[front] = 10000.0;
    sim.enemies.max_hp[front] = 10000.0;
    sim.advance();
    const base = sim.enemies.hp[front];

    // Spinach Core 5: +50% damage, so the same swing removes 30 instead of 20.
    p.passives[0] = 5;
    p.weapons[0].cooldown_ticks = 0;
    sim.enemies.hp[front] = 10000.0;
    sim.advance();
    const buffed = sim.enemies.hp[front];
    try std.testing.expectApproxEqAbs(base - 10.0, buffed, 1e-4);
}

test "Nano Repair restores HP over time" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);
    p.hp = 50.0;
    p.passives[9] = 5; // +4.0 HP/s

    var i: usize = 0;
    while (i < 60) : (i += 1) sim.advance();
    try std.testing.expectApproxEqAbs(@as(f32, 54.0), p.hp, 0.05);
}

test "Titanium Plating reduces contact damage" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);
    p.passives[8] = 5; // -15 flat, so 5 damage becomes the 1 minimum
    _ = sim.enemies.spawn(.circle_t1, .{ 0.6, 0.0 }).?;

    sim.advance();
    try std.testing.expectApproxEqAbs(@as(f32, 99.0), p.hp, 1e-4);
}

test "Overclock raises max HP without a cap" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);
    p.overclock[2] = 4; // +100 max HP
    p.max_hp += 100.0;
    p.hp = p.max_hp;
    try std.testing.expectEqual(@as(f32, 200.0), p.max_hp);
    try std.testing.expectEqual(@as(u8, 100), Simulation.hpPercent(p.hp, p.max_hp));
}

test "Overclock purchases past 255 do not wrap" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);

    // One purchase away from the old `u8` wrap on each counter.
    p.overclock[0] = 255;
    p.overclock[1] = 255;
    p.overclock[2] = 255;
    const hp_before = p.max_hp;

    sim.applyOption(0, .{ .item_id = upgrade.ids.overclock_damage, .next_level = 1, .is_evo = false });
    sim.applyOption(0, .{ .item_id = upgrade.ids.overclock_attack_speed, .next_level = 1, .is_evo = false });
    sim.applyOption(0, .{ .item_id = upgrade.ids.overclock_max_hp, .next_level = 1, .is_evo = false });

    // The counts land on 256, where the old `u8` + `+%=` wrapped to 0 and
    // silently dropped every bonus the player had bought.
    try std.testing.expectEqual(@as(u32, 256), p.overclock[0]);
    try std.testing.expectEqual(@as(u32, 256), p.overclock[1]);
    try std.testing.expectEqual(@as(u32, 256), p.overclock[2]);

    // The bonuses keep scaling instead of collapsing: +512% damage, the
    // clamped attack-speed floor, and another +25 max HP.
    const stats = upgrade.resolveStats(&p.weapons, &p.passives, &p.overclock);
    try std.testing.expectApproxEqAbs(@as(f32, 6.12), stats.damage_mult, 1e-6);
    try std.testing.expectApproxEqAbs(upgrade.overclock_cooldown_floor, stats.cooldown_mult, 1e-6);
    try std.testing.expectEqual(@as(f32, hp_before + 25.0), p.max_hp);
}

test "a restart resets the run and revives the player" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    disarm(p);
    p.level = 12;
    p.xp = 999;
    p.hp = 0.0;
    p.flags.alive = false;
    sim.state = .game_over;
    sim.kills = 40;
    _ = sim.enemies.spawn(.circle_t1, .{ 1.0, 1.0 }).?;

    sim.restart(0);
    try std.testing.expectEqual(GameState.running, sim.state);
    try std.testing.expect(p.flags.alive);
    try std.testing.expectEqual(@as(u16, 1), p.level);
    try std.testing.expectEqual(@as(u32, 0), p.xp);
    try std.testing.expectEqual(@as(f32, root.player_max_hp), p.hp);
    try std.testing.expectEqual(@as(u32, 0), sim.kills);
    try std.testing.expectEqual(@as(usize, 0), sim.enemies.count);
    try std.testing.expectEqual(@as(usize, 0), sim.gems.count);
}

test "the debug loadout arms the requested loadout and its evolution" {
    var sim = Simulation.init();
    sim.loadout = try loadout.parse("sword=8,clockwork_gear=5");
    const p = sim.spawnPlayer(0).?;

    // The sword is level 8 with Clockwork Gear at its max, so it is the Vorpal
    // Blender — the evolved id and the evolved flag, not just the levels.
    try std.testing.expectEqual(upgrade.ids.vorpal_blender, p.weapons[0].id);
    try std.testing.expect(p.weapons[0].evolved);
    try std.testing.expectEqual(root.max_weapon_level, p.weapons[0].level);
    try std.testing.expectEqual(@as(u8, 5), p.passives[2]);
    // The other three weapons keep the run's level-1 defaults.
    try std.testing.expectEqual(@as(u8, 1), p.weapons[1].level);
    try std.testing.expectEqual(upgrade.ids.axe, p.weapons[1].id);
    // Synergies are resolved from the loadout, not left at zero.
    try std.testing.expectEqual(upgrade.synergyMask(&p.weapons, &p.passives), p.synergy_mask);
}

test "the debug loadout survives a restart" {
    var sim = Simulation.init();
    sim.loadout = try loadout.parse("axe=8,amplifier_lens=5");
    _ = sim.spawnPlayer(0).?;
    const p = &sim.players[0];
    // A scripted restart has to start the next run partway there as well, so
    // the affordance is observable across a C2S_RESTART.
    p.weapons[0].level = 1;
    p.weapons[0].id = upgrade.ids.sword;
    p.weapons[0].evolved = false;
    p.passives[1] = 0;
    sim.restart(0);

    const i = upgrade.weaponSlot(&p.weapons, upgrade.ids.axe).?;
    try std.testing.expectEqual(upgrade.ids.gravity_cleaver, p.weapons[i].id);
    try std.testing.expect(p.weapons[i].evolved);
    try std.testing.expectEqual(@as(u8, 5), p.passives[1]);
    // The run itself is fresh again.
    try std.testing.expectEqual(@as(u16, 1), p.level);
    try std.testing.expectEqual(GameState.running, sim.state);
}

test "a run without the debug loadout keeps the default loadout" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    for (&p.weapons, 0..) |*slot, i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), slot.id);
        try std.testing.expectEqual(@as(u8, 1), slot.level);
        try std.testing.expect(!slot.evolved);
    }
    for (p.passives) |lvl| try std.testing.expectEqual(@as(u8, 0), lvl);
    try std.testing.expectEqual(@as(u16, 0), p.synergy_mask);
}

test "the score follows DESIGN.md §1" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    _ = p;
    sim.tick = 60 * 30; // 30 seconds
    sim.kills = 10;
    sim.players[0].level = 5;
    // 300 + 1250 + 20 = 1570
    try std.testing.expectEqual(@as(u32, 1570), sim.scoreFor(0));
}

test "the smoke test's difficulty escalation is unbounded" {
    // The spawn rate and active cap grow without a ceiling, which is what makes
    // the run escalate without bound.
    try std.testing.expect(enemy.spawnRate(10.0, 1) > enemy.spawnRate(1.0, 1));
    try std.testing.expect(enemy.activeCap(20.0) > enemy.activeCap(5.0));
    try std.testing.expectEqual(root.max_enemies, enemy.activeCap(1000.0));
    try std.testing.expect(enemy.spawnRate(100.0, 1) > 1000.0);
}

/// A player at the origin with no weapons, so nothing it does can kill the
/// shooter the test is setting up.
fn disarmedPlayerAtOrigin(sim: *Simulation) *PlayerState {
    const p = sim.spawnPlayer(0).?;
    p.pos = .{ 0.0, 0.0 };
    disarm(p);
    return p;
}

test "a spitter's shot travels at its stated speed" {
    var sim = Simulation.init();
    _ = disarmedPlayerAtOrigin(&sim);

    // A spitter 10 units away, halted and due to fire this tick.
    const s = sim.enemies.spawn(.triangle_t2, .{ 10.0, 0.0 }).?;
    sim.enemies.ai_state[s] = @intFromEnum(enemy.AiState.halt);
    sim.enemies.ai_timer[s] = 1;
    sim.updateEnemies(1.0 / 60.0);

    try std.testing.expectEqual(@as(usize, 1), sim.projectiles.count);
    const shot = sim.projectiles.count - 1;
    try std.testing.expectEqual(@as(u8, 0xff), sim.projectiles.owner_id[shot]);
    try std.testing.expectApproxEqAbs(
        @as(f32, enemy.spitter.shot_speed),
        std.math.hypot(sim.projectiles.vel[shot][0], sim.projectiles.vel[shot][1]),
        1e-4,
    );

    const x0 = sim.projectiles.pos[shot][0];
    var k: usize = 0;
    while (k < 10) : (k += 1) sim.advance();

    // Ten ticks at 9.0 u/s is 1.5 units of ground, not a shot sitting on the
    // muzzle for its whole lifetime.
    try std.testing.expectApproxEqAbs(
        @as(f32, enemy.spitter.shot_speed * 10.0 / 60.0),
        x0 - sim.projectiles.pos[shot][0],
        0.01,
    );
    try std.testing.expect(sim.projectiles.ttl_ticks[shot] > 0);
}

test "the boss's radial burst travels at its stated speed" {
    var sim = Simulation.init();
    _ = disarmedPlayerAtOrigin(&sim);

    const b = sim.enemies.spawn(.boss, .{ 30.0, 0.0 }).?;
    sim.enemies.ai_timer[b] = 1;
    sim.enemies.boss_parity[b] = 0;
    sim.updateEnemies(1.0 / 60.0);

    try std.testing.expectEqual(@as(usize, enemy.boss.burst_count), sim.projectiles.count);
    // The shot the burst fired along +x: the one with no y velocity.
    var along_x: ?usize = null;
    for (0..sim.projectiles.count) |j| {
        if (sim.projectiles.vel[j][1] == 0.0 and sim.projectiles.vel[j][0] > 0.0) along_x = j;
    }
    const shot = along_x orelse return error.NoRadialShot;

    const x0 = sim.projectiles.pos[shot][0];
    var k: usize = 0;
    while (k < 10) : (k += 1) sim.advance();

    try std.testing.expectApproxEqAbs(
        @as(f32, enemy.boss.burst_speed * 10.0 / 60.0),
        sim.projectiles.pos[shot][0] - x0,
        0.01,
    );
}

test "the endless move-speed escalation is applied when an enemy spawns" {
    var sim = Simulation.init();
    _ = disarmedPlayerAtOrigin(&sim);

    // Below 20:00 the multiplier is 1.0, so the curve changes nothing.
    sim.tick = 10 * 60 * root.tick_hz;
    sim.topUpLoad(1, 0, 5.0);
    try std.testing.expectEqual(@as(usize, 1), sim.enemies.count);
    try std.testing.expectApproxEqAbs(@as(f32, 4.5), sim.enemies.move_speed[0], 1e-5);

    // Past 20:00 a spawn carries the curve's multiplier.
    sim.tick = 25 * 60 * root.tick_hz;
    sim.topUpLoad(2, 0, 5.0);
    const want = 4.5 * enemy.speedMultiplier(25.0);
    try std.testing.expectApproxEqAbs(want, sim.enemies.move_speed[1], 1e-5);
    try std.testing.expect(sim.enemies.move_speed[1] > 4.5);

    // The boss takes it too — it is an enemy, and its spawn has no elite roll
    // to muddy the value.
    sim.spawnBoss(.{ 50.0, 0.0 }, 1.0, 1);
    try std.testing.expectEqual(@as(usize, 3), sim.enemies.count);
    try std.testing.expectApproxEqAbs(
        @as(f32, 5.5 * enemy.speedMultiplier(25.0)),
        sim.enemies.move_speed[2],
        1e-5,
    );

    // And the wave spawner, where the elite roll can only ever add speed: every
    // enemy it places past 20:00 is at least as fast as the curve demands, and
    // at most the Vampiric modifier faster. Both bounds fail if the curve is
    // not applied at all, and the elite roll's composition cannot break them.
    var i: usize = 0;
    while (i < 200) : (i += 1) sim.spawnEnemy(.circle_t1, .{ 50.0, 0.0 }, 1.0);
    try std.testing.expectEqual(@as(usize, 203), sim.enemies.count);
    var slowest: f32 = std.math.inf(f32);
    var fastest: f32 = 0.0;
    for (3..sim.enemies.count) |k| {
        slowest = @min(slowest, sim.enemies.move_speed[k]);
        fastest = @max(fastest, sim.enemies.move_speed[k]);
    }
    try std.testing.expect(slowest >= want - 1e-4);
    try std.testing.expect(fastest <= want * enemy.elite.vampiric_speed_mult + 1e-4);
    try std.testing.expect(fastest > 4.5);
}
