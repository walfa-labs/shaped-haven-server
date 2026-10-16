//! Shaped Haven server — the evolved weapons' lingering effects.
//!
//! Two things outlive the swing or the shot that created them:
//!
//! * **Ground rifts** (Gravity Cleaver, DESIGN.md §3) — a 3.0 s area that
//!   deals 40 damage per second to whatever stands in it.
//! * **Shatters** (Cryo Flechette, DESIGN.md §3) — an enemy that dies while
//!   frozen bursts for 120 area damage. The enemy pool queues the deaths;
//!   `processShatter` turns them into damage once the pool has been compacted.
//!
//! Both are driven from `sim.zig`, which owns the tick order.

const std = @import("std");
const root = @import("root.zig");
const enemy = @import("enemy.zig");
const combat = @import("combat.zig");
const spatial = @import("spatial.zig");

/// Live ground rifts, dense like the other pools.
pub const RiftPool = struct {
    count: usize = 0,
    pos: [root.max_rifts][2]f32 = @splat(.{ 0.0, 0.0 }),
    radius: [root.max_rifts]f32 = @splat(0.0),
    dps: [root.max_rifts]f32 = @splat(0.0),
    ttl_ticks: [root.max_rifts]u16 = @splat(0),

    /// Reserve a rift. `null` when the pool is full: a full pool degrades by
    /// dropping the rift, it does not crash.
    pub fn spawn(self: *RiftPool, pos: [2]f32, radius: f32, dps: f32, ttl_ticks: u16) ?usize {
        if (self.count >= root.max_rifts) return null;
        const i = self.count;
        self.pos[i] = pos;
        self.radius[i] = radius;
        self.dps[i] = dps;
        self.ttl_ticks[i] = ttl_ticks;
        self.count += 1;
        return i;
    }

    pub fn swapRemove(self: *RiftPool, i: usize) void {
        std.debug.assert(i < self.count);
        const last = self.count - 1;
        if (i != last) {
            inline for (@typeInfo(RiftPool).@"struct".field_names) |name| {
                if (comptime !std.mem.eql(u8, name, "count")) {
                    @field(self, name)[i] = @field(self, name)[last];
                }
            }
        }
        self.count -= 1;
    }

    /// Age every rift and compact the expired ones.
    pub fn reapExpired(self: *RiftPool) void {
        var i: usize = 0;
        while (i < self.count) {
            if (self.ttl_ticks[i] == 0) {
                self.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

/// Damage every enemy standing in a live rift for one tick.
pub fn updateRifts(
    rifts: *RiftPool,
    enemies: *enemy.Pool,
    grid: *const spatial.SpatialHash,
    scratch: []u32,
    dt: f32,
) void {
    var i: usize = 0;
    while (i < rifts.count) : (i += 1) {
        const n = grid.queryCircle(rifts.pos[i], rifts.radius[i] + enemy.max_radius, scratch);
        for (scratch[0..n]) |ei| {
            const e: usize = ei;
            if (!combat.circlesOverlap(rifts.pos[i], rifts.radius[i], enemies.pos[e], enemies.radius[e])) {
                continue;
            }
            // No knockback: the rift is a standing hazard, not a hit.
            _ = enemies.applyHit(e, rifts.dps[i] * dt, .{ 0.0, 0.0 }, 0.0);
        }
        if (rifts.ttl_ticks[i] != 0) rifts.ttl_ticks[i] -= 1;
    }
}

/// Turn the enemy pool's queued frozen deaths into Cryo Flechette shatters.
///
/// Called after `reapDead`, so the dead enemies are already gone and the grid
/// still covers everything alive.
pub fn processShatter(
    enemies: *enemy.Pool,
    grid: *const spatial.SpatialHash,
    scratch: []u32,
) void {
    for (0..enemies.shatter_count) |k| {
        const n = grid.queryCircle(enemies.shatter_pos[k], enemies.shatter_radius[k] + enemy.max_radius, scratch);
        for (scratch[0..n]) |ei| {
            const e: usize = ei;
            if (!combat.circlesOverlap(enemies.shatter_pos[k], enemies.shatter_radius[k], enemies.pos[e], enemies.radius[e])) {
                continue;
            }
            _ = enemies.applyHit(e, enemies.shatter_damage[k], combat.normalize(combat.sub(enemies.pos[e], enemies.shatter_pos[k])), 0.0);
        }
    }
    enemies.shatter_count = 0;
}

test "a rift damages what stands in it and expires" {
    var enemies = enemy.Pool{};
    var grid = spatial.SpatialHash{};
    grid.clear();
    var scratch: [64]u32 = undefined;

    const e = enemies.spawn(.circle_t1, .{ 0.0, 0.0 }).?;
    const far = enemies.spawn(.circle_t1, .{ 20.0, 0.0 }).?;
    for (0..enemies.count) |k| _ = grid.insert(@intCast(k), enemies.pos[k]);

    var rifts = RiftPool{};
    _ = rifts.spawn(.{ 0.0, 0.0 }, 3.0, 40.0, 10);

    updateRifts(&rifts, &enemies, &grid, &scratch, 1.0 / 60.0);
    // 40 damage per second for one tick, on the enemy inside the rift only.
    try std.testing.expectApproxEqAbs(@as(f32, 15.0 - 40.0 / 60.0), enemies.hp[e], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), enemies.hp[far], 1e-6);
    try std.testing.expectEqual(@as(u16, 9), rifts.ttl_ticks[0]);

    // Nine more ticks expire it.
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        updateRifts(&rifts, &enemies, &grid, &scratch, 1.0 / 60.0);
    }
    try std.testing.expectEqual(@as(u16, 0), rifts.ttl_ticks[0]);
    rifts.reapExpired();
    try std.testing.expectEqual(@as(usize, 0), rifts.count);
}

test "a shatter damages the enemies around a frozen death" {
    var enemies = enemy.Pool{};
    var grid = spatial.SpatialHash{};
    grid.clear();
    var scratch: [64]u32 = undefined;

    const centre = enemies.spawn(.circle_t1, .{ 0.0, 0.0 }).?;
    _ = enemies.spawn(.circle_t1, .{ 1.0, 0.0 }).?;
    _ = enemies.spawn(.circle_t1, .{ 20.0, 0.0 }).?;
    for (0..enemies.count) |k| _ = grid.insert(@intCast(k), enemies.pos[k]);

    // The centre enemy is frozen and dies.
    enemies.freeze_ticks[centre] = 10;
    enemies.hp[centre] = 0.0;
    _ = enemies.reapDead();
    try std.testing.expectEqual(@as(usize, 1), enemies.shatter_count);

    // `reapDead` compacts the pool, so the broadphase is rebuilt before the
    // shatter query — exactly what the tick does.
    grid.clear();
    for (0..enemies.count) |k| _ = grid.insert(@intCast(k), enemies.pos[k]);

    processShatter(&enemies, &grid, &scratch);
    // The survivor next to the burst took 120 damage; the distant one did not.
    // `reapDead` compacted the pool, so the survivors are found by position.
    var near_hp: f32 = 15.0;
    var far_hp: f32 = 15.0;
    for (0..enemies.count) |i| {
        if (std.math.hypot(enemies.pos[i][0] - 1.0, enemies.pos[i][1]) < 0.1) near_hp = enemies.hp[i];
        if (std.math.hypot(enemies.pos[i][0] - 20.0, enemies.pos[i][1]) < 0.1) far_hp = enemies.hp[i];
    }
    try std.testing.expect(near_hp <= 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), far_hp, 1e-6);
    try std.testing.expectEqual(@as(usize, 0), enemies.shatter_count);
}
