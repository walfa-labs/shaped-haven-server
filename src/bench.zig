//! Shaped Haven server — the phase-2 load measurement.
//!
//! DESIGN.md §6 sets the phase-2 definition of done as *"1,000 active enemies
//! and 500 projectiles run under 4.0 ms/tick"*. This module produces exactly
//! that world and times the tick, so the number in the README and the PR is a
//! measurement rather than an estimate.
//!
//! What is timed: `Simulation.advance` and nothing else. The harness that keeps
//! the load topped up between ticks is *not* inside the measurement — it stands
//! in for the spawner, which the server does not charge to the tick either.
//!
//! Why the load is topped up. Enemies die and projectiles expire, so a world
//! seeded once with 1,000 and 500 would drain over the run and measure a
//! shrinking world. Refilling to the target every tick measures the *sustained*
//! cost of the load the DoD names, which is the number that matters.
//!
//! Run it in a release build — a Debug build's safety checks dominate:
//!
//! ```sh
//! zig build test -Doptimize=ReleaseFast
//! ```

const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const sim = @import("sim.zig");
const enemy = @import("enemy.zig");
const weapon = @import("weapon.zig");

/// The load DESIGN.md §6 names.
pub const default_enemies: usize = 1000;
pub const default_projectiles: usize = 500;
/// Ticks measured after the warm-up.
pub const default_ticks: usize = 240;

/// The budget DESIGN.md §6 sets, in milliseconds per tick.
pub const budget_ms: f64 = 4.0;

/// Enemies are seeded inside this radius of the player so every weapon has
/// targets and every broadphase query has a realistic number of candidates.
/// Packing them close is the *worst* case for the combat pass, which is what
/// the DoD is about.
const load_radius: f32 = 35.0;

/// Warm-up ticks, run before the measurement so page faults on the first touch
/// of the pools and caches do not land inside it.
const warmup_ticks: usize = 30;

pub const Report = struct {
    ticks: usize,
    enemies: usize,
    projectiles: usize,
    /// Mean and worst tick, in nanoseconds.
    mean_ns: f64,
    max_ns: f64,
    /// The mean converted to the unit the DoD is stated in.
    mean_ms: f64,
    /// Mean live counts actually present during the timed ticks, and the kills
    /// the simulation scored. Evidence that the load was real and that the
    /// combat pass was doing work, rather than a tick measured on an idle world.
    mean_live_enemies: f64,
    mean_live_projectiles: f64,
    kills: u32,
    /// The build mode the measurement was taken in. Debug keeps bounds checks
    /// and panics on every array access, which is a different order of cost
    /// from the release build the server ships at, so a timing means nothing
    /// without this.
    mode: []const u8,

    pub fn passes(self: Report) bool {
        return self.mean_ms < budget_ms;
    }
};

/// Run the load and time it.
pub fn run(
    gpa: std.mem.Allocator,
    want_enemies: usize,
    want_projectiles: usize,
    ticks: usize,
) !Report {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const s = try gpa.create(sim.Simulation);
    defer gpa.destroy(s);
    s.* = sim.Simulation.init();

    const player = s.spawnPlayer(0).?;
    player.pos = .{ 0.0, 0.0 };

    topUp(s, want_enemies, want_projectiles);

    var i: usize = 0;
    while (i < warmup_ticks) : (i += 1) {
        s.advance();
        topUp(s, want_enemies, want_projectiles);
    }

    var total_ns: i96 = 0;
    var max_ns: i96 = 0;
    var sum_enemies: usize = 0;
    var sum_projs: usize = 0;
    i = 0;
    while (i < ticks) : (i += 1) {
        // Counted before the tick, because the tick is what removes them.
        sum_enemies += s.enemies.count;
        sum_projs += s.projectiles.count;

        const before = std.Io.Clock.Timestamp.now(io, .awake);
        s.advance();
        const after = std.Io.Clock.Timestamp.now(io, .awake);
        const elapsed = before.durationTo(after).raw.nanoseconds;
        total_ns += elapsed;
        max_ns = @max(max_ns, elapsed);
        topUp(s, want_enemies, want_projectiles);
    }

    const fticks: f64 = @floatFromInt(ticks);
    const mean_ns = @as(f64, @floatFromInt(total_ns)) / fticks;
    return .{
        .ticks = ticks,
        .enemies = want_enemies,
        .projectiles = want_projectiles,
        .mean_ns = mean_ns,
        .max_ns = @floatFromInt(max_ns),
        .mean_ms = mean_ns / @as(f64, std.time.ns_per_ms),
        .mean_live_enemies = @as(f64, @floatFromInt(sum_enemies)) / fticks,
        .mean_live_projectiles = @as(f64, @floatFromInt(sum_projs)) / fticks,
        .kills = s.kills,
        .mode = @tagName(builtin.mode),
    };
}

/// Refill the world to the target load, spawning near the player so the combat
/// pass always has work to do. The simulation owns the placement, so the
/// benchmark and the server's `--stress-enemies` mode build the same world.
fn topUp(s: *sim.Simulation, want_enemies: usize, want_projectiles: usize) void {
    s.topUpLoad(want_enemies, want_projectiles, load_radius);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "1,000 enemies and 500 projectiles stay inside the phase-2 tick budget" {
    const report = try run(std.testing.allocator, default_enemies, default_projectiles, default_ticks);

    std.debug.print(
        "\n[bench] {s} build, {d} ticks with {d} enemies and {d} projectiles: " ++
            "mean {d:.3} ms/tick, worst {d:.3} ms/tick (budget {d:.1} ms)\n" ++
            "[bench] live during the run: {d:.0} enemies, {d:.0} projectiles; " ++
            "{d} kills\n",
        .{
            report.mode,
            report.ticks,
            report.enemies,
            report.projectiles,
            report.mean_ms,
            report.max_ns / @as(f64, std.time.ns_per_ms),
            budget_ms,
            report.mean_live_enemies,
            report.mean_live_projectiles,
            report.kills,
        },
    );

    // The measurement only means anything if the world was really loaded, and
    // "really loaded" means the counts the DoD names — not merely close to them.
    // The counts are sampled before each tick, after the top-up that follows the
    // previous one, so this is the load the world was actually holding.
    try std.testing.expectEqual(
        @as(f64, @floatFromInt(report.enemies)),
        report.mean_live_enemies,
    );
    try std.testing.expectEqual(
        @as(f64, @floatFromInt(report.projectiles)),
        report.mean_live_projectiles,
    );
    // ... and the combat pass was doing work, not ticking over an idle world.
    try std.testing.expect(report.kills > 0);

    // The budget is only meaningful in a release build: Debug keeps bounds
    // checks and panics on every array access, which is a different order of
    // cost. The looser Debug bound still catches a pathological regression.
    const limit = if (builtin.mode == .debug) budget_ms * 10.0 else budget_ms;
    if (report.mean_ms >= limit) {
        std.debug.print(
            "[bench] FAIL: {d:.3} ms/tick exceeds the {d:.1} ms limit for this build mode\n",
            .{ report.mean_ms, limit },
        );
        return error.TickBudgetExceeded;
    }
}

test "the load actually reaches the counts the report claims" {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();

    var s = sim.Simulation.init();
    const player = s.spawnPlayer(0).?;
    player.pos = .{ 0.0, 0.0 };
    topUp(&s, 1000, 500);

    try std.testing.expectEqual(@as(usize, 1000), s.enemies.count);
    try std.testing.expectEqual(@as(usize, 500), s.projectiles.count);

    // A tick on its own drains the world, which is what the top-up is for.
    s.advance();
    try std.testing.expect(s.enemies.count < 1000);
    try std.testing.expect(s.projectiles.count < 500);

    // The top-up puts it back exactly, every time, and never grows either pool
    // past the load it is holding.
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        topUp(&s, 1000, 500);
        try std.testing.expectEqual(@as(usize, 1000), s.enemies.count);
        try std.testing.expectEqual(@as(usize, 500), s.projectiles.count);
        s.advance();
        try std.testing.expect(s.enemies.count <= 1000);
        try std.testing.expect(s.projectiles.count <= 500);
    }

    // The pool caps still hold under a deliberately oversized target.
    topUp(&s, root.max_enemies + 1000, root.max_projectiles + 1000);
    try std.testing.expectEqual(root.max_enemies, s.enemies.count);
    try std.testing.expectEqual(root.max_projectiles, s.projectiles.count);
}
