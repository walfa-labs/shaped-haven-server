//! Shaped Haven server — deterministic simulation core.
//!
//! This module is deliberately free of I/O: it owns player state and advances
//! it one fixed 60 Hz step at a time. Networking lives in `server.zig`, which
//! feeds inputs in and reads snapshots out.
//!
//! Phase 1 implements exactly what DESIGN.md §6 asks for: the player kinematic
//! integrator. Enemy, projectile and gem pools arrive with later phases; the
//! `players` array is a fixed pool indexed by `player_id` so the layout is
//! already what multiplayer needs.

const std = @import("std");
const root = @import("root.zig");
const wire = @import("wire.zig");

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

    players: [root.max_players]PlayerState = root.filledWithDefault(PlayerState, root.max_players),
    /// Scratch space for the snapshot encoder; keeps encoding allocation-free.
    net_scratch: [root.max_players]wire.PlayerNet = root.filledWithDefault(wire.PlayerNet, root.max_players),

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
            return &self.players[requested_slot];
        }
        for (&self.players) |*p| {
            if (!p.active) {
                p.active = true;
                return p;
            }
        }
        return null;
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
    pub fn advance(self: *Simulation) void {
        if (self.state != .running) return;
        const dt = tickDurationSeconds();
        for (&self.players) |*p| {
            if (p.active) p.integrate(dt);
        }
        self.tick += 1;
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

    /// HP as a whole percentage, the form `hp_pct` carries on the wire.
    pub fn hpPercent(hp: f32, max_hp: f32) u8 {
        if (max_hp <= 0.0) return 0;
        return @intFromFloat(std.math.clamp(std.math.round(hp / max_hp * 100.0), 0.0, 100.0));
    }

    /// Snapshot payload contents. `players` borrows `net_scratch`, so the view
    /// is only valid until the next call on this same `Simulation`.
    pub fn snapshotView(self: *Simulation) wire.SnapshotView {
        var n: usize = 0;
        for (&self.players) |*p| {
            if (!p.active) continue;
            self.net_scratch[n] = playerNet(p);
            n += 1;
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
                self.activePlayerCount(),
                0,
                0,
                0,
            },
            .players = self.net_scratch[0..n],
            .enemies = &.{},
            .projs = &.{},
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
