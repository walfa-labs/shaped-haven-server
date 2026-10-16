//! Shaped Haven server — deterministic simulation core.
//!
//! This module is deliberately free of I/O: it owns the world state and
//! advances it one fixed 60 Hz step at a time. Networking lives in `server.zig`,
//! which feeds inputs in and reads snapshots out.
//!
//! Phase 2 implements DESIGN.md §6's combat core: the enemy pool and the Tier 1
//! spawn curve (§4), the four weapons at their level 1 stats (§3), and arc /
//! circle hit detection with knockback over a uniform spatial hash grid. XP
//! gems, upgrades and player death are phase 3.
//!
//! The order of systems inside a tick is fixed, because determinism depends on
//! it:
//!
//! 1. players integrate their input;
//! 2. enemies run their AI, integrate, and are clamped to the arena;
//! 3. the broadphase grid is rebuilt from the enemies' new positions;
//! 4. every ready weapon acquires the nearest enemy and fires — arcs damage
//!    immediately, projectiles are spawned;
//! 5. projectiles travel and resolve what they overlap;
//! 6. enemies touching a player deal contact damage;
//! 7. dead enemies and spent projectiles are compacted out of their pools;
//! 8. once per second the spawn formula is evaluated.
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

/// One weapon a player carries (DESIGN.md §2 `WeaponSlot`).
///
/// Phase 2 gives every player all four weapons at level 1 from the first tick;
/// the levels, cooldown modifiers and evolutions of DESIGN.md §3 are phase 3.
pub const WeaponSlot = struct {
    id: u8 = 0,
    level: u8 = 1,
    cooldown_ticks: u16 = 0,
    evolved: bool = false,

    pub fn spec(slot: WeaponSlot) ?weapon.Spec {
        return weapon.spec(slot.id);
    }
};

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

/// A player's HP never falls below this in phase 2: death and game over are
/// phase 3, so a run cannot end yet and the HUD is allowed to sit at 1%.
pub const player_hp_floor: f32 = 1.0;

/// Fixed seed for the spawn RNG, so a run is reproducible. A phase that wants
/// per-run variety changes this at `Simulation.init`, not here.
pub const spawn_seed: u64 = 0x5eed5eed5eed5eed;

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

/// One player in the simulation (DESIGN.md §2 field list, phase-1 subset).
pub const PlayerState = struct {
    id: u8 = 0,
    active: bool = false,
    flags: StateFlags = .{},
    pos: [2]f32 = .{ 0.0, 0.0 },
    vel: [2]f32 = .{ 0.0, 0.0 },
    aim_dir: [2]f32 = .{ 1.0, 0.0 },
    hp: f32 = root.player_max_hp,
    max_hp: f32 = root.player_max_hp,
    xp: u32 = 0,
    level: u16 = 1,
    weapons: [root.max_weapons]WeaponSlot = root.filledWithDefault(WeaponSlot, root.max_weapons),
    input: InputFrame = .{},
    /// Last `input_seq` the server has applied; reported back to the client as
    /// `acked_seq` so it can reconcile its prediction ring buffer.
    last_input_seq: u32 = 0,

    /// Integrate one fixed step. Pure function of `(input, dt)`.
    pub fn integrate(p: *PlayerState, dt: f32) void {
        var mx: f32 = @as(f32, @floatFromInt(p.input.move_x)) / 100.0;
        var my: f32 = @as(f32, @floatFromInt(p.input.move_y)) / 100.0;

        // Keep diagonal movement at the same speed as axis-aligned movement.
        const mag = std.math.hypot(mx, my);
        if (mag > 1.0) {
            mx /= mag;
            my /= mag;
        }

        p.vel[0] = mx * root.move_speed;
        p.vel[1] = my * root.move_speed;
        p.pos[0] += p.vel[0] * dt;
        p.pos[1] += p.vel[1] * dt;

        // Hard arena walls (DESIGN.md §1). The collider is clamped so the whole
        // 1.0 x 1.0 square stays inside [-1000, 1000].
        const limit = root.arena_half_size - root.player_half_extent;
        p.pos[0] = std.math.clamp(p.pos[0], -limit, limit);
        p.pos[1] = std.math.clamp(p.pos[1], -limit, limit);

        if (mag > 0.0001) p.aim_dir = .{ mx, my };
    }
};

/// Fixed-timestep simulation. One instance per running game.
pub const Simulation = struct {
    tick: u32 = 0,
    state: GameState = .running,
    /// Enemies killed since the run started. Phase 2 only reports it; the score
    /// that consumes it is phase 4.
    kills: u32 = 0,

    players: [root.max_players]PlayerState = root.filledWithDefault(PlayerState, root.max_players),

    enemies: enemy.Pool = .{},
    projectiles: combat.ProjectilePool = .{},
    /// Broadphase over the enemy pool, rebuilt once per tick.
    grid: spatial.SpatialHash = .{},

    /// Spawn RNG. Seeded from a constant so a run is reproducible: the same
    /// seed and the same inputs produce the same enemies in the same places.
    rng: rng.Rng = rng.Rng.init(spawn_seed),
    /// Fractional spawns carried between spawn evaluations, so the rate curve
    /// is not rounded down once per second.
    spawn_accum: f32 = 0.0,
    /// When set, the world is held at this load every tick instead of being
    /// populated by the spawn curve. See `StressLoad`.
    stress: ?StressLoad = null,

    /// Scratch space for the snapshot encoder; keeps encoding allocation-free.
    net_scratch: [root.max_players]wire.PlayerNet = root.filledWithDefault(wire.PlayerNet, root.max_players),
    net_enemies: [root.max_enemies]wire.EnemyNet = @splat(std.mem.zeroes(wire.EnemyNet)),
    net_projs: [root.max_projectiles]wire.ProjNet = @splat(std.mem.zeroes(wire.ProjNet)),
    /// Scratch space for broadphase results, shared by every query in a tick.
    /// Sized for the whole enemy pool because one query can legitimately match
    /// every enemy in the world.
    query_scratch: [root.max_enemies]u32 = @splat(0),

    pub fn init() Simulation {
        var self = Simulation{};
        for (0..root.max_players, &self.players) |i, *p| {
            p.id = @intCast(i);
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
            equipStarterWeapons(&self.players[requested_slot]);
            return &self.players[requested_slot];
        }
        for (&self.players) |*p| {
            if (!p.active) {
                p.active = true;
                equipStarterWeapons(p);
                return p;
            }
        }
        return null;
    }

    /// Give a joining player the four level 1 weapons of DESIGN.md §3.
    ///
    /// Cooldowns start at zero, so all four fire on the player's first tick.
    fn equipStarterWeapons(p: *PlayerState) void {
        p.weapons = root.filledWithDefault(WeaponSlot, root.max_weapons);
        for (&p.weapons, 0..) |*slot, i| {
            slot.id = @intCast(i);
            slot.level = 1;
            slot.cooldown_ticks = 0;
            slot.evolved = false;
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
        if (self.state != .running) return;
        const dt = tickDurationSeconds();

        for (&self.players) |*p| {
            if (p.active) p.integrate(dt);
        }

        self.updateEnemies(dt);
        self.rebuildGrid();
        self.updateWeapons();
        combat.updateProjectiles(
            &self.projectiles,
            &self.enemies,
            &self.grid,
            &self.query_scratch,
            dt,
        );
        self.updateContact();

        self.kills += @intCast(self.enemies.reapDead());
        self.projectiles.reapSpent();

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
        const limit = root.arena_half_size - enemy.max_radius;
        const gun = weapon.spec(@intFromEnum(weapon.Id.gun)) orelse return;

        while (self.projectiles.count < want_projectiles) {
            const angle = self.rng.range(0.0, 2.0 * std.math.pi);
            const dist = self.rng.range(2.0, radius);
            const dir = [2]f32{ @cos(angle), @sin(angle) };
            const pos = [2]f32{
                std.math.clamp(around[0] + dir[0] * dist, -limit, limit),
                std.math.clamp(around[1] + dir[1] * dist, -limit, limit),
            };
            if (self.projectiles.spawn(0, gun, pos, dir) == null) break;
        }

        while (self.enemies.count < want_enemies) {
            const angle = self.rng.range(0.0, 2.0 * std.math.pi);
            const dist = self.rng.range(1.0, radius);
            const pos = [2]f32{
                std.math.clamp(around[0] + @cos(angle) * dist, -limit, limit),
                std.math.clamp(around[1] + @sin(angle) * dist, -limit, limit),
            };
            if (self.enemies.spawn(.circle_t1, pos) == null) break;
        }
    }

    /// Centroid of the alive players, or `null` when nobody is connected.
    pub fn playerCentroid(self: *const Simulation) ?[2]f32 {
        var sum = [2]f32{ 0.0, 0.0 };
        var n: u32 = 0;
        for (&self.players) |p| {
            if (!p.active) continue;
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
            if (!p.active) continue;
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
    fn updateEnemies(self: *Simulation, dt: f32) void {
        const limit = root.arena_half_size;
        var i: usize = 0;
        while (i < self.enemies.count) : (i += 1) {
            if (self.enemies.contact_cd[i] > 0) self.enemies.contact_cd[i] -= 1;

            const archetype: enemy.Archetype = @enumFromInt(self.enemies.archetype[i]);
            const target = self.nearestPlayer(self.enemies.pos[i]);
            var vel = [2]f32{ 0.0, 0.0 };

            if (target) |pi| {
                const to_player = combat.sub(self.players[pi].pos, self.enemies.pos[i]);
                const dist = std.math.hypot(to_player[0], to_player[1]);
                const dir = combat.normalize(to_player);

                switch (archetype) {
                    .triangle_t1 => {
                        vel = self.darterStep(i, dir, dist);
                    },
                    else => {
                        vel = .{ dir[0] * self.enemies.move_speed[i], dir[1] * self.enemies.move_speed[i] };
                    },
                }
            } else {
                self.enemies.ai_state[i] = @intFromEnum(enemy.AiState.pursue);
                self.enemies.ai_timer[i] = 0;
            }
            self.enemies.vel[i] = vel;

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
        }
    }

    fn rebuildGrid(self: *Simulation) void {
        self.grid.clear();
        var i: usize = 0;
        while (i < self.enemies.count) : (i += 1) {
            self.grid.insert(@intCast(i), self.enemies.pos[i]);
        }
    }

    /// Tick every weapon cooldown and fire what is ready.
    ///
    /// The nearest enemy is looked up once per player per tick rather than once
    /// per weapon: with four weapons that is four broadphase queries saved, and
    /// all four aim at the same target anyway.
    fn updateWeapons(self: *Simulation) void {
        for (&self.players) |*p| {
            if (!p.active) continue;

            var any_ready = false;
            for (&p.weapons) |*slot| {
                if (slot.cooldown_ticks > 0) slot.cooldown_ticks -= 1;
                if (slot.cooldown_ticks == 0 and slot.spec() != null) any_ready = true;
            }
            if (!any_ready) continue;

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
                const spec = slot.spec() orelse continue;
                if (weapon.isArc(spec)) {
                    _ = combat.fireArc(
                        &self.enemies,
                        &self.grid,
                        &self.projectiles,
                        p.id,
                        spec,
                        p.pos,
                        dir,
                        &self.query_scratch,
                    );
                } else {
                    _ = self.projectiles.spawn(p.id, spec, p.pos, dir);
                }
                slot.cooldown_ticks = spec.cooldown_ticks;
            }
        }
    }

    /// Contact damage: an enemy overlapping a player's 1.0 x 1.0 square hurts
    /// it, at most once per `enemy.contact_cooldown_ticks`.
    fn updateContact(self: *Simulation) void {
        const half = root.player_half_extent;
        const reach = half * std.math.sqrt2 + enemy.max_radius;

        for (&self.players) |*p| {
            if (!p.active or p.flags.invulnerable) continue;
            const n = self.grid.queryCircle(p.pos, reach, &self.query_scratch);
            for (self.query_scratch[0..n]) |ei| {
                const e: usize = ei;
                if (self.enemies.contact_cd[e] > 0) continue;
                if (!combat.boxCircleOverlap(p.pos, half, self.enemies.pos[e], self.enemies.radius[e])) {
                    continue;
                }
                self.enemies.contact_cd[e] = enemy.contact_cooldown_ticks;
                // Floors at 1 HP: player death is phase 3, so a run cannot end
                // yet and the client's HP bar is allowed to sit at 1%.
                p.hp = @max(p.hp - self.enemies.contact_dmg[e], player_hp_floor);
            }
        }
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
        self.spawn_accum -= @floatFromInt(owed);

        const cap = enemy.activeCap(t);
        const centroid = self.playerCentroid() orelse return;
        const limit = root.arena_half_size - enemy.max_radius;
        // One axis per wave: a surge has to cluster the whole wave into two
        // opposing arcs, which only works if every enemy is measured from the
        // same direction.
        const axis = enemy.surgeAxis(&self.rng, self.tick);

        while (owed > 0) : (owed -= 1) {
            if (self.enemies.count >= cap) break;
            const archetype = enemy.pickArchetype(&self.rng, self.tick);
            const angle = enemy.spawnAngle(&self.rng, axis);
            const dist = self.rng.range(enemy.spawn_min_radius, enemy.spawn_max_radius);
            const pos = [2]f32{
                std.math.clamp(centroid[0] + @cos(angle) * dist, -limit, limit),
                std.math.clamp(centroid[1] + @sin(angle) * dist, -limit, limit),
            };
            // A full pool stops the loop rather than being skipped: the next
            // evaluation will try again.
            if (self.enemies.spawn(archetype, pos) == null) break;
        }
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
        const vel = pool.vel[i];
        return .{
            .id = pool.id[i],
            .archetype = pool.archetype[i],
            .elite_mask = pool.elite_mask[i],
            .pos_x = wire.quantize(pos[0]),
            .pos_y = wire.quantize(pos[1]),
            .vel_angle = wire.angleToByte(std.math.atan2(vel[1], vel[0])),
            .hp_pct = hpPercent(pool.hp[i], pool.max_hp[i]),
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
                0,
            },
            .players = self.net_scratch[0..np],
            .enemies = self.net_enemies[0..ne],
            .projs = self.net_projs[0..nk],
            .gems = &.{},
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

test "contact damage hurts the player and floors at 1 HP" {
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

    // However long it stays, HP never reaches zero: death is phase 3.
    i = 0;
    while (i < 3000) : (i += 1) sim.advance();
    try std.testing.expectApproxEqAbs(player_hp_floor, p.hp, 1e-6);
    try std.testing.expect(Simulation.hpPercent(p.hp, p.max_hp) == 1);
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

test "the snapshot carries the enemy and projectile arrays" {
    var sim = Simulation.init();
    const p = sim.spawnPlayer(0).?;
    _ = p;

    const e0 = sim.enemies.spawn(.circle_t1, .{ 3.0, -4.0 }).?;
    const e1 = sim.enemies.spawn(.triangle_t1, .{ -7.0, 2.0 }).?;
    sim.enemies.hp[e1] = 5.0;
    const gun = weapon.spec(@intFromEnum(weapon.Id.gun)).?;
    _ = sim.projectiles.spawn(0, gun, .{ 1.0, 1.0 }, .{ 1.0, 0.0 }).?;

    const view = sim.snapshotView();
    try std.testing.expectEqual(@as(u16, 1), view.counts[0]);
    try std.testing.expectEqual(@as(u16, 2), view.counts[1]);
    try std.testing.expectEqual(@as(u16, 1), view.counts[2]);
    try std.testing.expectEqual(@as(u16, 0), view.counts[3]);
    try std.testing.expectEqual(@as(usize, 2), view.enemies.len);
    try std.testing.expectEqual(@as(usize, 1), view.projs.len);

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

    // The wire layout is header, then players, enemies, projectiles, gems.
    const frame = try wire.encodeSnapshotFull(std.testing.allocator, view);
    defer std.testing.allocator.free(frame);
    try std.testing.expectEqual(
        @as(usize, wire.header_size + wire.snapshot_header_wire_size +
            8 * 1 + 12 * 2 + 12 * 1),
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
