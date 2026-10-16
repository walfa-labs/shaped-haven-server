//! Shaped Haven server — projectiles, hit detection and damage.
//!
//! Everything here is the *effect* of a weapon: the projectile pool, the three
//! hit shapes DESIGN.md §2 names (arc / circle / ray), the damage and knockback
//! a hit applies, and the broadphase queries that decide which enemies a hit
//! has to consider. `sim.zig` owns the tick order and calls into this.
//!
//! Geometry note. Travelling projectiles are tested as a circle against a
//! circle at their new position, with no swept test between the old and the new
//! position. At the speeds DESIGN.md §3 gives, that cannot tunnel: the fastest
//! projectile covers 28/60 = 0.47 units per tick, and the smallest combined
//! radius (gun 0.25 + swarmer 0.5) is 0.75 — larger than the step, so a
//! projectile cannot cross a hitbox and leave it again inside one tick.

const std = @import("std");
const root = @import("root.zig");
const wire = @import("wire.zig");
const weapon = @import("weapon.zig");
const enemy = @import("enemy.zig");
const spatial = @import("spatial.zig");

/// Distinct enemies one projectile can remember hitting. A projectile is spent
/// the moment its pierce reaches zero, so it can never need more entries than
/// the largest travelling weapon's pierce.
pub const max_hits_per_projectile: usize = 2;

comptime {
    if (weapon.max_projectile_hits > max_hits_per_projectile) {
        @compileError("max_hits_per_projectile is smaller than the largest weapon pierce");
    }
}

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

pub fn sub(a: [2]f32, b: [2]f32) [2]f32 {
    return .{ a[0] - b[0], a[1] - b[1] };
}

/// Unit vector in the direction of `v`; `(1, 0)` when `v` is degenerate, so a
/// zero-length direction can never produce a NaN.
pub fn normalize(v: [2]f32) [2]f32 {
    const len = std.math.hypot(v[0], v[1]);
    if (len < 1e-6) return .{ 1.0, 0.0 };
    return .{ v[0] / len, v[1] / len };
}

/// True when two circles overlap or touch.
pub fn circlesOverlap(a: [2]f32, ra: f32, b: [2]f32, rb: f32) bool {
    const d = sub(a, b);
    const r = ra + rb;
    return d[0] * d[0] + d[1] * d[1] <= r * r;
}

/// True when a circle overlaps an axis-aligned box, the shape of a player
/// collider (DESIGN.md §1: a 1.0 x 1.0 square).
pub fn boxCircleOverlap(center: [2]f32, half: f32, c: [2]f32, r: f32) bool {
    const dx = @max(@abs(c[0] - center[0]) - half, 0.0);
    const dy = @max(@abs(c[1] - center[1]) - half, 0.0);
    return dx * dx + dy * dy <= r * r;
}

/// True when a circle of radius `point_radius` at `point` is inside the sector
/// that starts at `origin`, points along the unit vector `dir`, extends `reach`
/// units and is `2 * half_arc` wide.
///
/// The angular test is widened by the half-angle the circle subtends at its
/// distance (`asin(r / d)`), so an enemy whose body is inside the arc counts
/// even when its centre is just outside — otherwise a wide, slow enemy would
/// slip through the edge of a swing it visibly overlaps.
pub fn sectorContains(
    origin: [2]f32,
    dir: [2]f32,
    reach: f32,
    half_arc: f32,
    point: [2]f32,
    point_radius: f32,
) bool {
    const d = sub(point, origin);
    const dist = std.math.hypot(d[0], d[1]);
    if (dist > reach + point_radius) return false;
    if (dist <= point_radius) return true; // overlapping the origin: always in range

    const cos_angle = std.math.clamp((d[0] * dir[0] + d[1] * dir[1]) / dist, -1.0, 1.0);
    const angle = std.math.acos(cos_angle);
    const slack = std.math.asin(std.math.clamp(point_radius / dist, 0.0, 1.0));
    return angle <= half_arc + slack;
}

// ---------------------------------------------------------------------------
// Projectile pool
// ---------------------------------------------------------------------------

pub const ProjectilePool = struct {
    /// Live projectiles, all in slots `[0, count)`.
    count: usize = 0,
    next_id: u32 = 1,

    id: [root.max_projectiles]u32 = @splat(0),
    owner_id: [root.max_projectiles]u8 = @splat(0),
    weapon_id: [root.max_projectiles]u8 = @splat(0),
    shape: [root.max_projectiles]u8 = @splat(0),
    pos: [root.max_projectiles][2]f32 = @splat(.{ 0.0, 0.0 }),
    /// Velocity in units per second for a travelling projectile. An `arc`
    /// record does not travel, so for those this holds the unit facing vector
    /// instead — which is what keeps the wire's `vel_angle` meaningful for a
    /// swing.
    vel: [root.max_projectiles][2]f32 = @splat(.{ 0.0, 0.0 }),
    damage: [root.max_projectiles]f32 = @splat(0.0),
    pierce_remaining: [root.max_projectiles]u8 = @splat(0),
    ttl_ticks: [root.max_projectiles]u16 = @splat(0),
    /// Entity ids already hit, so a projectile cannot damage the same enemy
    /// twice while it is still overlapping it.
    hit_ids: [root.max_projectiles][max_hits_per_projectile]u32 = @splat(.{ 0, 0 }),
    hit_count: [root.max_projectiles]u8 = @splat(0),

    pub fn shapeOf(self: *const ProjectilePool, i: usize) wire.ProjShape {
        return @enumFromInt(self.shape[i]);
    }

    /// True when this record takes part in collisions. An `arc` record is a
    /// rendered swing whose damage was already applied by `fireArc`.
    pub fn collides(self: *const ProjectilePool, i: usize) bool {
        return self.shapeOf(i) != .arc;
    }

    /// Reserve a slot for `spec` fired from `pos` along the unit vector `dir`.
    /// `null` when the pool is full: a full pool degrades, it does not crash.
    pub fn spawn(
        self: *ProjectilePool,
        owner_id: u8,
        spec: weapon.Spec,
        pos: [2]f32,
        dir: [2]f32,
    ) ?usize {
        if (self.count >= root.max_projectiles) return null;

        const i = self.count;
        const facing = normalize(dir);
        const arc = weapon.isArc(spec);
        self.id[i] = self.next_id;
        self.next_id +%= 1;
        self.owner_id[i] = owner_id;
        self.weapon_id[i] = @intFromEnum(spec.id);
        self.shape[i] = @intFromEnum(spec.shape);
        self.pos[i] = pos;
        self.vel[i] = if (arc) facing else .{ facing[0] * spec.speed, facing[1] * spec.speed };
        // An arc's damage is applied by the sector test at the moment it fires,
        // so its record carries none and never collides.
        self.damage[i] = if (arc) 0.0 else spec.damage;
        self.pierce_remaining[i] = spec.pierce;
        self.ttl_ticks[i] = spec.ttl_ticks;
        self.hit_ids[i] = .{ 0, 0 };
        self.hit_count[i] = 0;
        self.count += 1;
        return i;
    }

    pub fn swapRemove(self: *ProjectilePool, i: usize) void {
        std.debug.assert(i < self.count);
        const last = self.count - 1;
        if (i != last) {
            inline for (@typeInfo(ProjectilePool).@"struct".field_names) |name| {
                if (comptime !std.mem.eql(u8, name, "count") and
                    !std.mem.eql(u8, name, "next_id"))
                {
                    @field(self, name)[i] = @field(self, name)[last];
                }
            }
        }
        self.count -= 1;
    }

    /// True when this projectile has already damaged `enemy_id`.
    pub fn alreadyHit(self: *const ProjectilePool, i: usize, enemy_id: u32) bool {
        var k: usize = 0;
        while (k < self.hit_count[i]) : (k += 1) {
            if (self.hit_ids[i][k] == enemy_id) return true;
        }
        return false;
    }

    fn recordHit(self: *ProjectilePool, i: usize, enemy_id: u32) void {
        if (self.hit_count[i] >= max_hits_per_projectile) return;
        self.hit_ids[i][self.hit_count[i]] = enemy_id;
        self.hit_count[i] += 1;
    }

    /// Compact away spent projectiles. A record is spent when its lifetime runs
    /// out, or — for a travelling one — when its pierce is used up.
    pub fn reapSpent(self: *ProjectilePool) void {
        var i: usize = 0;
        while (i < self.count) {
            const spent = self.ttl_ticks[i] == 0 or
                (self.collides(i) and self.pierce_remaining[i] == 0);
            if (spent) {
                self.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Hit resolution
// ---------------------------------------------------------------------------

/// Index of the nearest live enemy within `max_range` of `from`, or `null`.
///
/// The broadphase supplies the candidates; the distance test decides. Enemies
/// are points here, so the range is measured centre to centre.
pub fn nearestEnemy(
    grid: *const spatial.SpatialHash,
    enemies: *const enemy.Pool,
    from: [2]f32,
    max_range: f32,
    scratch: []u32,
) ?usize {
    const n = grid.queryCircle(from, max_range, scratch);
    var best: ?usize = null;
    var best_d2 = std.math.inf(f32);
    for (scratch[0..n]) |ei| {
        const e: usize = ei;
        const d = sub(enemies.pos[e], from);
        const d2 = d[0] * d[0] + d[1] * d[1];
        if (d2 < best_d2) {
            best_d2 = d2;
            best = e;
        }
    }
    return best;
}

/// Apply an arc weapon's sector to every enemy inside it. Returns how many were
/// hit.
///
/// Instantaneous: the sweep damages the whole sector on the tick it fires, and
/// the `arc` record spawned afterwards is a rendering-only echo of it.
pub fn fireArc(
    enemies: *enemy.Pool,
    grid: *const spatial.SpatialHash,
    projectiles: *ProjectilePool,
    owner_id: u8,
    spec: weapon.Spec,
    origin: [2]f32,
    dir: [2]f32,
    scratch: []u32,
) usize {
    const half_arc = spec.arc_rad * 0.5;
    const n = grid.queryCircle(origin, spec.reach + enemy.max_radius, scratch);

    var pierce = spec.pierce;
    var hits: usize = 0;
    for (scratch[0..n]) |ei| {
        if (pierce == 0) break;
        const e: usize = ei;
        if (!sectorContains(origin, dir, spec.reach, half_arc, enemies.pos[e], enemies.radius[e])) {
            continue;
        }
        _ = enemies.applyHit(e, spec.damage, normalize(sub(enemies.pos[e], origin)), spec.knockback);
        pierce -= 1;
        hits += 1;
    }

    _ = projectiles.spawn(owner_id, spec, origin, dir);
    return hits;
}

/// Move every travelling projectile, resolve what it hits, and apply damage.
///
/// Dead enemies are only marked here (their HP is at or below zero); compacting
/// the pool happens after every grid query for the tick, so the indices this
/// loop is holding stay valid for its whole run.
pub fn updateProjectiles(
    projectiles: *ProjectilePool,
    enemies: *enemy.Pool,
    grid: *const spatial.SpatialHash,
    scratch: []u32,
    dt: f32,
) void {
    const arena = root.arena_half_size;

    var i: usize = 0;
    while (i < projectiles.count) : (i += 1) {
        if (projectiles.ttl_ticks[i] == 0) continue; // spent, reaped at the end of the tick
        projectiles.ttl_ticks[i] -= 1;

        if (!projectiles.collides(i)) continue;

        projectiles.pos[i][0] += projectiles.vel[i][0] * dt;
        projectiles.pos[i][1] += projectiles.vel[i][1] * dt;

        // Past the arena wall: nothing left to hit.
        if (@abs(projectiles.pos[i][0]) > arena or @abs(projectiles.pos[i][1]) > arena) {
            projectiles.ttl_ticks[i] = 0;
            continue;
        }

        const spec = weapon.spec(projectiles.weapon_id[i]) orelse {
            projectiles.ttl_ticks[i] = 0;
            continue;
        };
        const dir = normalize(projectiles.vel[i]);
        const n = grid.queryCircle(
            projectiles.pos[i],
            spec.radius + enemy.max_radius,
            scratch,
        );

        for (scratch[0..n]) |ei| {
            const e: usize = ei;
            if (projectiles.alreadyHit(i, enemies.id[e])) continue;
            if (!circlesOverlap(projectiles.pos[i], spec.radius, enemies.pos[e], enemies.radius[e])) {
                continue;
            }

            _ = enemies.applyHit(e, projectiles.damage[i], dir, spec.knockback);
            projectiles.recordHit(i, enemies.id[e]);
            if (projectiles.pierce_remaining[i] > 0) projectiles.pierce_remaining[i] -= 1;
            if (projectiles.pierce_remaining[i] == 0) {
                projectiles.ttl_ticks[i] = 0;
                break;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn emptyGrid() spatial.SpatialHash {
    var g = spatial.SpatialHash{};
    g.clear();
    return g;
}

test "normalize returns a unit vector and never divides by zero" {
    const a = normalize(.{ 3.0, 4.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), a[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), a[1], 1e-6);

    try std.testing.expectEqual([2]f32{ 1.0, 0.0 }, normalize(.{ 0.0, 0.0 }));
}

test "circle overlap includes touching" {
    try std.testing.expect(circlesOverlap(.{ 0, 0 }, 0.5, .{ 1.0, 0 }, 0.5));
    try std.testing.expect(circlesOverlap(.{ 0, 0 }, 0.5, .{ 0.9, 0 }, 0.4));
    try std.testing.expect(!circlesOverlap(.{ 0, 0 }, 0.5, .{ 1.01, 0 }, 0.5));
    try std.testing.expect(circlesOverlap(.{ 0, 0 }, 0.5, .{ 0, 0 }, 0.5));
}

test "a circle overlaps the square player collider" {
    // Dead centre, and just touching each face.
    try std.testing.expect(boxCircleOverlap(.{ 0, 0 }, 0.5, .{ 0, 0 }, 0.5));
    try std.testing.expect(boxCircleOverlap(.{ 0, 0 }, 0.5, .{ 1.0, 0 }, 0.5));
    try std.testing.expect(boxCircleOverlap(.{ 0, 0 }, 0.5, .{ 0.0, 1.0 }, 0.5));
    // Diagonally at the corner: (0.5, 0.5) is exactly sqrt(2)/2 away.
    try std.testing.expect(boxCircleOverlap(.{ 0, 0 }, 0.5, .{ 0.5, 0.5 }, 0.5));
    try std.testing.expect(!boxCircleOverlap(.{ 0, 0 }, 0.5, .{ 1.01, 0.0 }, 0.5));
    try std.testing.expect(!boxCircleOverlap(.{ 0, 0 }, 0.5, .{ 0.0, -1.01 }, 0.5));
}

test "the sword sector is 90 degrees wide and 3.5 units deep" {
    const origin = [2]f32{ 0.0, 0.0 };
    const dir = [2]f32{ 1.0, 0.0 };
    const half = std.math.pi / 4.0;

    // Straight ahead, at the reach limit.
    try std.testing.expect(sectorContains(origin, dir, 3.5, half, .{ 3.5, 0.0 }, 0.0));
    try std.testing.expect(!sectorContains(origin, dir, 3.5, half, .{ 3.51, 0.0 }, 0.0));
    // Just inside the 45 degree edge, and just outside it.
    try std.testing.expect(sectorContains(origin, dir, 3.5, half, .{ 2.0, 1.9 }, 0.0));
    try std.testing.expect(!sectorContains(origin, dir, 3.5, half, .{ 2.0, 2.1 }, 0.0));
    // Directly behind.
    try std.testing.expect(!sectorContains(origin, dir, 3.5, half, .{ -1.0, 0.0 }, 0.0));
    // Behind, but close enough that the body reaches into the sector.
    try std.testing.expect(sectorContains(origin, dir, 3.5, half, .{ -0.4, 0.0 }, 0.5));

    // An enemy whose edge reaches past the reach limit still counts.
    try std.testing.expect(sectorContains(origin, dir, 3.5, half, .{ 3.9, 0.0 }, 0.5));
    try std.testing.expect(!sectorContains(origin, dir, 3.5, half, .{ 4.1, 0.0 }, 0.5));
}

test "the axe sector is 160 degrees wide" {
    const origin = [2]f32{ 0.0, 0.0 };
    const dir = [2]f32{ 1.0, 0.0 };
    const half = 80.0 * std.math.pi / 180.0;

    try std.testing.expect(sectorContains(origin, dir, 5.0, half, .{ 4.0, 2.0 }, 0.0));
    // 79 degrees off axis.
    const inside = [2]f32{ @cos(79.0 * std.math.pi / 180.0), @sin(79.0 * std.math.pi / 180.0) };
    try std.testing.expect(sectorContains(origin, dir, 5.0, half, .{ inside[0] * 3.0, inside[1] * 3.0 }, 0.0));
    // 81 degrees off axis.
    const outside = [2]f32{ @cos(81.0 * std.math.pi / 180.0), @sin(81.0 * std.math.pi / 180.0) };
    try std.testing.expect(!sectorContains(origin, dir, 5.0, half, .{ outside[0] * 3.0, outside[1] * 3.0 }, 0.0));
    // A swing this wide still leaves a gap behind the player.
    try std.testing.expect(!sectorContains(origin, dir, 5.0, half, .{ -4.0, 0.0 }, 0.0));
}

test "spawning a projectile fills the pool and then degrades" {
    var pool = ProjectilePool{};
    const spec = weapon.spec(@intFromEnum(weapon.Id.gun)).?;
    var i: usize = 0;
    while (i < root.max_projectiles) : (i += 1) {
        try std.testing.expect(pool.spawn(0, spec, .{ 0, 0 }, .{ 1, 0 }) != null);
    }
    try std.testing.expect(pool.spawn(0, spec, .{ 0, 0 }, .{ 1, 0 }) == null);
    try std.testing.expectEqual(root.max_projectiles, pool.count);
}

test "a projectile record carries the spec's numbers and a unit direction" {
    var pool = ProjectilePool{};
    const spec = weapon.spec(@intFromEnum(weapon.Id.bow)).?;
    const i = pool.spawn(2, spec, .{ 4.0, -4.0 }, .{ 0.0, 3.0 }).?;

    try std.testing.expectEqual(@as(u8, 2), pool.owner_id[i]);
    try std.testing.expectEqual(@intFromEnum(weapon.Id.bow), pool.weapon_id[i]);
    try std.testing.expectEqual(@intFromEnum(wire.ProjShape.ray), pool.shape[i]);
    try std.testing.expectEqual([2]f32{ 4.0, -4.0 }, pool.pos[i]);
    // Normalized, then scaled by the 18 u/s arrow speed.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), pool.vel[i][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 18.0), pool.vel[i][1], 1e-6);
    try std.testing.expectEqual(@as(f32, 30.0), pool.damage[i]);
    try std.testing.expectEqual(@as(u8, 2), pool.pierce_remaining[i]);
    try std.testing.expectEqual(@as(u16, 120), pool.ttl_ticks[i]);
    try std.testing.expect(pool.collides(i));
}

test "an arc record carries no damage and does not collide" {
    var pool = ProjectilePool{};
    const spec = weapon.spec(@intFromEnum(weapon.Id.sword)).?;
    const i = pool.spawn(0, spec, .{ 1.0, 1.0 }, .{ 0.0, 1.0 }).?;

    try std.testing.expectEqual(@as(f32, 0.0), pool.damage[i]);
    try std.testing.expectEqual(@intFromEnum(wire.ProjShape.arc), pool.shape[i]);
    try std.testing.expect(!pool.collides(i));
    // An arc does not travel, so `vel` is the unit facing vector: the wire's
    // `vel_angle` still says which way the swing went.
    try std.testing.expectEqual([2]f32{ 0.0, 1.0 }, pool.vel[i]);
    try std.testing.expectEqual(@as(u16, 9), pool.ttl_ticks[i]);
}

test "an arc fires once, damages the whole sector, and leaves a record behind" {
    var enemies = enemy.Pool{};
    var grid = emptyGrid();
    var projectiles = ProjectilePool{};
    var scratch: [64]u32 = undefined;

    // Three swarmers ahead within reach, one behind, one out of reach.
    const front_a = enemies.spawn(.circle_t1, .{ 1.0, 0.0 }).?;
    const front_b = enemies.spawn(.circle_t1, .{ 2.5, 1.0 }).?;
    const front_far = enemies.spawn(.circle_t1, .{ 9.0, 0.0 }).?;
    const behind = enemies.spawn(.circle_t1, .{ -1.0, 0.0 }).?;
    for (0..enemies.count) |k| grid.insert(@intCast(k), enemies.pos[k]);

    const spec = weapon.spec(@intFromEnum(weapon.Id.sword)).?;
    const hits = fireArc(&enemies, &grid, &projectiles, 0, spec, .{ 0, 0 }, .{ 1, 0 }, &scratch);

    try std.testing.expectEqual(@as(usize, 2), hits);
    // 15 HP against a 20 damage sword leaves -5, which is the death marker the
    // pool reaps on.
    try std.testing.expectApproxEqAbs(@as(f32, -5.0), enemies.hp[front_a], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -5.0), enemies.hp[front_b], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), enemies.hp[front_far], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), enemies.hp[behind], 1e-6);

    // The swing pushed the survivors-adjacent enemies outward.
    try std.testing.expect(enemies.kb[front_a][0] > 0.0);

    // One arc record, for the client to draw.
    try std.testing.expectEqual(@as(usize, 1), projectiles.count);
    try std.testing.expect(!projectiles.collides(0));
}

test "the axe reaches further and hits a wider sector than the sword" {
    var enemies = enemy.Pool{};
    var grid = emptyGrid();
    var projectiles = ProjectilePool{};
    var scratch: [64]u32 = undefined;

    // 4.5 units out and 60 degrees off axis: inside the axe, outside the sword.
    const a = @as(f32, 60.0) * std.math.pi / 180.0;
    const p = [2]f32{ @cos(a) * 4.5, @sin(a) * 4.5 };
    const target = enemies.spawn(.circle_t1, p).?;
    for (0..enemies.count) |k| grid.insert(@intCast(k), enemies.pos[k]);

    const sword = weapon.spec(@intFromEnum(weapon.Id.sword)).?;
    try std.testing.expectEqual(@as(usize, 0), fireArc(&enemies, &grid, &projectiles, 0, sword, .{ 0, 0 }, .{ 1, 0 }, &scratch));
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), enemies.hp[target], 1e-6);

    const axe = weapon.spec(@intFromEnum(weapon.Id.axe)).?;
    try std.testing.expectEqual(@as(usize, 1), fireArc(&enemies, &grid, &projectiles, 0, axe, .{ 0, 0 }, .{ 1, 0 }, &scratch));
    try std.testing.expectApproxEqAbs(@as(f32, -30.0), enemies.hp[target], 1e-6); // 15 - 45
}

test "a gun bullet damages one enemy, is spent, and cannot hit it twice" {
    var enemies = enemy.Pool{};
    var grid = emptyGrid();
    var projectiles = ProjectilePool{};
    var scratch: [64]u32 = undefined;

    const target = enemies.spawn(.circle_t1, .{ 1.0, 0.0 }).?;
    for (0..enemies.count) |k| grid.insert(@intCast(k), enemies.pos[k]);

    const spec = weapon.spec(@intFromEnum(weapon.Id.gun)).?;
    _ = projectiles.spawn(0, spec, .{ 0.0, 0.0 }, .{ 1.0, 0.0 }).?;

    // The bullet starts 1.0 units away and closes 0.47 units per tick.
    const dt = 1.0 / 60.0;
    var ticks: usize = 0;
    while (ticks < 10) : (ticks += 1) {
        updateProjectiles(&projectiles, &enemies, &grid, &scratch, dt);
        projectiles.reapSpent();
        if (enemies.hp[target] < 15.0) break;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), enemies.hp[target], 1e-5); // 15 - 12
    // Pierce 1: spent on the first hit, so it never fires again.
    try std.testing.expectEqual(@as(usize, 0), projectiles.count);
}

test "a bow arrow pierces two enemies and then stops" {
    var enemies = enemy.Pool{};
    var grid = emptyGrid();
    var projectiles = ProjectilePool{};
    var scratch: [64]u32 = undefined;

    // Three swarmers in a line along +x, spaced so the arrow reaches them in
    // turn: it is spent after the second.
    const first = enemies.spawn(.circle_t1, .{ 1.0, 0.0 }).?;
    const second = enemies.spawn(.circle_t1, .{ 3.0, 0.0 }).?;
    const third = enemies.spawn(.circle_t1, .{ 5.0, 0.0 }).?;
    for (0..enemies.count) |k| grid.insert(@intCast(k), enemies.pos[k]);

    const spec = weapon.spec(@intFromEnum(weapon.Id.bow)).?;
    try std.testing.expect(projectiles.spawn(0, spec, .{ 0.0, 0.0 }, .{ 1.0, 0.0 }) != null);

    const dt = 1.0 / 60.0;
    var ticks: usize = 0;
    while (ticks < 60) : (ticks += 1) {
        updateProjectiles(&projectiles, &enemies, &grid, &scratch, dt);
        projectiles.reapSpent();
    }

    // Both of the first two took exactly one 30 damage hit (15 -> -15).
    try std.testing.expectApproxEqAbs(@as(f32, -15.0), enemies.hp[first], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -15.0), enemies.hp[second], 1e-5);
    // The third was never reached: the arrow was spent after two hits.
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), enemies.hp[third], 1e-5);
    try std.testing.expectEqual(@as(usize, 0), projectiles.count);
}

test "a projectile that never hits expires on its lifetime" {
    var enemies = enemy.Pool{};
    var grid = emptyGrid();
    var projectiles = ProjectilePool{};
    var scratch: [64]u32 = undefined;

    const spec = weapon.spec(@intFromEnum(weapon.Id.gun)).?;
    _ = projectiles.spawn(0, spec, .{ 0.0, 0.0 }, .{ 1.0, 0.0 }).?;

    const dt = 1.0 / 60.0;
    var ticks: usize = 0;
    while (ticks < 72) : (ticks += 1) {
        updateProjectiles(&projectiles, &enemies, &grid, &scratch, dt);
        projectiles.reapSpent();
    }
    try std.testing.expectEqual(@as(usize, 0), projectiles.count);
}

test "a projectile leaving the arena is spent" {
    var enemies = enemy.Pool{};
    var grid = emptyGrid();
    var projectiles = ProjectilePool{};
    var scratch: [64]u32 = undefined;

    const spec = weapon.spec(@intFromEnum(weapon.Id.gun)).?;
    _ = projectiles.spawn(0, spec, .{ root.arena_half_size - 0.1, 0.0 }, .{ 1.0, 0.0 }).?;

    updateProjectiles(&projectiles, &enemies, &grid, &scratch, 1.0 / 60.0);
    try std.testing.expectEqual(@as(u16, 0), projectiles.ttl_ticks[0]);
    projectiles.reapSpent();
    try std.testing.expectEqual(@as(usize, 0), projectiles.count);
}

test "nearestEnemy picks the closest candidate inside the range" {
    var enemies = enemy.Pool{};
    var grid = emptyGrid();
    var scratch: [64]u32 = undefined;

    _ = enemies.spawn(.circle_t1, .{ 30.0, 0.0 }).?;
    const near = enemies.spawn(.circle_t1, .{ 2.0, 2.0 }).?;
    _ = enemies.spawn(.circle_t1, .{ -9.0, 0.0 }).?;
    for (0..enemies.count) |k| grid.insert(@intCast(k), enemies.pos[k]);

    try std.testing.expectEqual(near, nearestEnemy(&grid, &enemies, .{ 0, 0 }, 45.0, &scratch).?);
    // Nothing within 1 unit.
    try std.testing.expect(nearestEnemy(&grid, &enemies, .{ 0, 0 }, 1.0, &scratch) == null);
}

test "swapRemove keeps the projectile pool dense" {
    var pool = ProjectilePool{};
    const spec = weapon.spec(@intFromEnum(weapon.Id.gun)).?;
    _ = pool.spawn(0, spec, .{ 1.0, 1.0 }, .{ 1, 0 }).?;
    _ = pool.spawn(1, spec, .{ 2.0, 2.0 }, .{ 1, 0 }).?;
    const c = pool.spawn(2, spec, .{ 3.0, 3.0 }, .{ 1, 0 }).?;
    const moved = pool.id[c];

    pool.swapRemove(0);
    try std.testing.expectEqual(@as(usize, 2), pool.count);
    try std.testing.expectEqual(moved, pool.id[0]);
    try std.testing.expectEqual([2]f32{ 3.0, 3.0 }, pool.pos[0]);
    try std.testing.expectEqual(@as(u8, 2), pool.owner_id[0]);
    try std.testing.expectEqual(@as(u8, 1), pool.pierce_remaining[0]);
}
