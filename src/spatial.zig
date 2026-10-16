//! Shaped Haven server — uniform spatial hash grid (DESIGN.md §6, phase 2).
//!
//! Broadphase for every combat query. Enemies are inserted once per tick and
//! every hit test asks the grid for the candidates near a point instead of
//! walking the whole pool, which is what keeps a tick with a thousand enemies
//! inside the 4.0 ms budget.
//!
//! Why a *hash* grid and not a dense array over the arena. The arena is
//! 2000 x 2000 units, so at the 4.0 unit cell size DESIGN.md §6 fixes it is
//! 500 x 500 cells. Clearing that every tick would cost 250,000 writes — more
//! than the entire combat pass. A fixed 8192-bucket table is cleared with 32 KB
//! of writes instead, and the chain walk is short because at most 4096 entities
//! are ever stored.
//!
//! Collisions are handled by storing each slot's cell alongside it: a bucket is
//! only the first filter, and the query skips any slot whose cell is not the
//! one it is scanning. Without that check a slot would be visited once per
//! colliding cell in the scan range and the same entity would be returned
//! several times. With it, a collision costs time and nothing else, and the
//! results are exact: the cell check narrows, the distance test decides.
//!
//! Pure data structure: no allocation, no I/O, no reference to the entity pools.
//! `insert` takes an entity index and a position; queries hand those indices
//! back.

const std = @import("std");
const root = @import("root.zig");

/// Cell edge length in world units (DESIGN.md §6).
pub const cell_size: f32 = 4.0;

/// Half the arena in cells. Positions are clamped into the arena by the
/// simulation, so a query can stop here instead of walking an unbounded range.
const cell_limit: i32 = 252;

pub const SpatialHash = struct {
    /// Power of two, so the bucket index is a mask rather than a modulo.
    pub const bucket_count: usize = 8192;
    pub const capacity: usize = root.max_enemies;

    /// Bucket heads, -1 when empty. Holds *slots*, not entity indices, so a
    /// bucket can be walked without touching the entity pools.
    buckets: [bucket_count]i32 = @splat(-1),
    /// The entity index this slot was inserted with.
    ids: [capacity]u32 = @splat(0),
    /// The cell the slot was filed under, which is what makes a bucket
    /// collision harmless.
    cell_x: [capacity]i32 = @splat(0),
    cell_y: [capacity]i32 = @splat(0),
    xs: [capacity]f32 = @splat(0.0),
    ys: [capacity]f32 = @splat(0.0),
    /// Next slot in the same bucket, -1 at the end of the chain.
    next: [capacity]i32 = @splat(-1),
    /// Slots in use. Never more than `capacity`.
    len: usize = 0,

    /// Drop every entry. O(bucket_count), not O(arena).
    pub fn clear(self: *SpatialHash) void {
        @memset(&self.buckets, -1);
        self.len = 0;
    }

    /// Insert `index` at `pos`. Silently dropped once the grid is full: a full
    /// pool must degrade, and the entity is still simulated either way — it
    /// just stops being a broadphase candidate.
    pub fn insert(self: *SpatialHash, index: u32, pos: [2]f32) void {
        if (self.len >= capacity) return;
        const slot = self.len;
        const cx = cellOf(pos[0]);
        const cy = cellOf(pos[1]);
        const bucket = bucketIndex(cx, cy);
        self.ids[slot] = index;
        self.cell_x[slot] = cx;
        self.cell_y[slot] = cy;
        self.xs[slot] = pos[0];
        self.ys[slot] = pos[1];
        self.next[slot] = self.buckets[bucket];
        self.buckets[bucket] = @intCast(slot);
        self.len += 1;
    }

    /// Entity indices whose stored position lies within `radius` of `center`,
    /// written into `out`. Returns how many were written. Each index appears at
    /// most once.
    ///
    /// Exact, not approximate: candidates come from the cells the circle
    /// overlaps, and membership is decided by the distance test, so hash
    /// collisions only add work. `out` should be at least `capacity` long; a
    /// shorter buffer truncates rather than overflowing.
    pub fn queryCircle(
        self: *const SpatialHash,
        center: [2]f32,
        radius: f32,
        out: []u32,
    ) usize {
        if (!(radius >= 0.0)) return 0;

        const r2 = radius * radius;
        const min_cx = @max(cellOf(center[0] - radius), -cell_limit);
        const max_cx = @min(cellOf(center[0] + radius), cell_limit);
        const min_cy = @max(cellOf(center[1] - radius), -cell_limit);
        const max_cy = @min(cellOf(center[1] + radius), cell_limit);

        var found: usize = 0;
        var cy = min_cy;
        while (cy <= max_cy) : (cy += 1) {
            var cx = min_cx;
            while (cx <= max_cx) : (cx += 1) {
                var slot = self.buckets[bucketIndex(cx, cy)];
                while (slot >= 0) {
                    const s: usize = @intCast(slot);
                    const next = self.next[s];
                    // A bucket holds every cell that hashed to it; only the one
                    // being scanned may be reported.
                    if (self.cell_x[s] == cx and self.cell_y[s] == cy) {
                        const dx = self.xs[s] - center[0];
                        const dy = self.ys[s] - center[1];
                        if (dx * dx + dy * dy <= r2) {
                            if (found >= out.len) return found;
                            out[found] = self.ids[s];
                            found += 1;
                        }
                    }
                    slot = next;
                }
            }
        }
        return found;
    }
};

/// Cell coordinate containing `v`.
fn cellOf(v: f32) i32 {
    // Clamped before the float-to-int conversion so a NaN or an absurd query
    // centre cannot trap in a safety-checked build.
    return @intFromFloat(@floor(std.math.clamp(v / cell_size, -1.0e6, 1.0e6)));
}

/// Mix two cell coordinates into a bucket index.
fn bucketIndex(cx: i32, cy: i32) usize {
    var h: u32 = @bitCast(cx);
    h *%= 0x9E3779B1;
    h ^= @as(u32, @bitCast(cy)) *% 0x85EBCA6B;
    h ^= h >> 15;
    return h & (SpatialHash.bucket_count - 1);
}

test "a cleared grid holds nothing" {
    var grid = SpatialHash{};
    grid.clear();
    var out: [16]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), grid.queryCircle(.{ 0, 0 }, 100.0, &out));
    try std.testing.expectEqual(@as(usize, 0), grid.len);
}

test "queryCircle finds what was inserted and nothing else" {
    var grid = SpatialHash{};
    grid.clear();
    grid.insert(10, .{ 0.0, 0.0 });
    grid.insert(11, .{ 3.9, 0.0 }); // same cell as the origin
    grid.insert(12, .{ 4.1, 0.0 }); // next cell along
    grid.insert(13, .{ -4.1, 0.0 }); // next cell the other way
    grid.insert(14, .{ 0.0, 4.1 });
    grid.insert(15, .{ 500.0, -500.0 }); // far away
    try std.testing.expectEqual(@as(usize, 6), grid.len);

    var out: [16]u32 = undefined;
    var n = grid.queryCircle(.{ 0, 0 }, 4.05, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    // Both sit in cell (0, 0), and the chain is last-in-first-out.
    try std.testing.expectEqualSlices(u32, &.{ 11, 10 }, out[0..n]);

    // Exactly on the boundary counts as inside.
    n = grid.queryCircle(.{ 0, 0 }, 4.1, &out);
    try std.testing.expectEqual(@as(usize, 5), n);

    // A radius that reaches nothing.
    try std.testing.expectEqual(@as(usize, 0), grid.queryCircle(.{ 200, 200 }, 1.0, &out));

    // The far entry is found on its own.
    n = grid.queryCircle(.{ 500.0, -500.0 }, 0.5, &out);
    try std.testing.expectEqualSlices(u32, &.{15}, out[0..n]);
}

test "no entity is reported twice, even when cells collide in a bucket" {
    var grid = SpatialHash{};
    grid.clear();
    // One point per cell over a 100 x 40 block: 4000 cells against 8192
    // buckets, so hundreds of those cells necessarily share a bucket. Without
    // the cell check in the query, every shared bucket would be walked once per
    // colliding cell in the scan range and the same point would come back more
    // than once.
    const cols: i32 = 100;
    const rows: i32 = 40;
    var id: u32 = 0;
    var cy: i32 = 0;
    while (cy < rows) : (cy += 1) {
        var cx: i32 = 0;
        while (cx < cols) : (cx += 1) {
            grid.insert(id, .{
                @as(f32, @floatFromInt(cx)) * cell_size + 0.5,
                @as(f32, @floatFromInt(cy)) * cell_size + 0.5,
            });
            id += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 4000), grid.len);

    var out: [SpatialHash.capacity]u32 = undefined;
    const n = grid.queryCircle(.{ 200.0, 80.0 }, 400.0, &out);
    try std.testing.expectEqual(@as(usize, 4000), n);

    var seen: [4000]bool = @splat(false);
    for (out[0..n]) |idx| {
        try std.testing.expect(!seen[idx]);
        seen[idx] = true;
    }
}

test "queryCircle reaches across cell boundaries" {
    var grid = SpatialHash{};
    grid.clear();
    // 64 points on a ring of radius 20, which spans many 4.0 unit cells.
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const a = @as(f32, @floatFromInt(i)) * (2.0 * std.math.pi / 64.0);
        grid.insert(@intCast(i), .{ @cos(a) * 20.0, @sin(a) * 20.0 });
    }

    var out: [128]u32 = undefined;
    // A query whose centre sits on a cell corner still finds every ring point.
    const n = grid.queryCircle(.{ 4.0, 4.0 }, 40.0, &out);
    try std.testing.expectEqual(@as(usize, 64), n);

    // Every returned index is distinct.
    var seen: [64]bool = @splat(false);
    for (out[0..n]) |idx| {
        try std.testing.expect(!seen[idx]);
        seen[idx] = true;
    }
}

test "a full grid drops entries instead of overrunning" {
    var grid = SpatialHash{};
    grid.clear();
    var i: usize = 0;
    while (i < SpatialHash.capacity + 32) : (i += 1) {
        grid.insert(@intCast(i), .{ @as(f32, @floatFromInt(i)) * 0.1, 0.0 });
    }
    try std.testing.expectEqual(SpatialHash.capacity, grid.len);

    var out: [SpatialHash.capacity]u32 = undefined;
    const n = grid.queryCircle(.{ 200, 0 }, 500.0, &out);
    try std.testing.expectEqual(SpatialHash.capacity, n);
}

test "a query buffer smaller than the result set truncates rather than overflows" {
    var grid = SpatialHash{};
    grid.clear();
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        grid.insert(@intCast(i), .{ @as(f32, @floatFromInt(i)) * 0.01, 0.0 });
    }
    var out: [8]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 8), grid.queryCircle(.{ 0, 0 }, 100.0, &out));
}

test "clear resets the chains so stale entries cannot be found" {
    var grid = SpatialHash{};
    grid.clear();
    grid.insert(1, .{ 5.0, 5.0 });
    var out: [8]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 1), grid.queryCircle(.{ 5.0, 5.0 }, 1.0, &out));

    grid.clear();
    try std.testing.expectEqual(@as(usize, 0), grid.queryCircle(.{ 5.0, 5.0 }, 1.0, &out));
    grid.insert(2, .{ 5.0, 5.0 });
    const n = grid.queryCircle(.{ 5.0, 5.0 }, 1.0, &out);
    try std.testing.expectEqualSlices(u32, &.{2}, out[0..n]);
}

test "a negative radius finds nothing" {
    var grid = SpatialHash{};
    grid.clear();
    grid.insert(1, .{ 0.0, 0.0 });
    var out: [8]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), grid.queryCircle(.{ 0, 0 }, -1.0, &out));
}

test "cellOf clamps instead of trapping on absurd input" {
    try std.testing.expectEqual(@as(i32, 0), cellOf(0.0));
    try std.testing.expectEqual(@as(i32, 1), cellOf(4.0));
    try std.testing.expectEqual(@as(i32, -1), cellOf(-0.1));
    _ = cellOf(std.math.inf(f32));
    _ = cellOf(-std.math.inf(f32));
}
