//! Shaped Haven server — XP gem pool (DESIGN.md §2, §4).
//!
//! Structure-of-arrays like the other pools: one flat array per field, a live
//! count at the front, dense slots. A gem is stationary until a player comes
//! inside that player's pickup radius, at which point it is magnetized to them
//! and flies toward them until it is collected. `magnet_target_id` is `0xff`
//! while the gem is still stationary, which is the state PROTOCOL.md's
//! `GemNet` carries.
//!
//! The pool holds no update logic: `sim.zig` owns the tick order and drives the
//! magnet, the collection and the XP award, because those need the players.

const std = @import("std");
const root = @import("root.zig");
const wire = @import("wire.zig");

/// `magnet_target_id` value for a gem that is not flying at anyone.
pub const no_magnet: u8 = 0xff;

/// Gem values (DESIGN.md §1): Small 2, Medium 10, Large 50, Boss Cache 250.
pub const small_xp: u16 = 2;
pub const medium_xp: u16 = 10;
pub const large_xp: u16 = 50;
pub const boss_cache_xp: u16 = 250;

/// XP a dead enemy drops, by archetype. Elites drop 5x (DESIGN.md §4).
pub fn gemValue(archetype: u8, elite_mask: u8) u16 {
    const a: wire.EnemyArchetype = @enumFromInt(archetype);
    const base: u16 = switch (a) {
        .circle_t1, .triangle_t1 => small_xp,
        .circle_t2, .triangle_t2 => medium_xp,
        .circle_t3, .triangle_t3 => large_xp,
        .boss => boss_cache_xp,
    };
    if (elite_mask != 0) return base * 5;
    return base;
}

pub const Pool = struct {
    /// Live gems, all in slots `[0, count)`.
    count: usize = 0,
    /// Next entity id. Ids are never reused, so a swap-remove cannot make the
    /// client mistake one gem for another.
    next_id: u32 = 1,

    id: [root.max_gems]u32 = @splat(0),
    pos: [root.max_gems][2]f32 = @splat(.{ 0.0, 0.0 }),
    xp_value: [root.max_gems]u16 = @splat(0),
    magnet_target: [root.max_gems]u8 = @splat(no_magnet),

    /// Reserve a slot. `null` when the pool is full: a full pool degrades by
    /// dropping the gem, it does not crash.
    pub fn spawn(self: *Pool, pos: [2]f32, xp_value: u16) ?usize {
        if (self.count >= root.max_gems) return null;
        const i = self.count;
        self.id[i] = self.next_id;
        self.next_id +%= 1;
        self.pos[i] = pos;
        self.xp_value[i] = xp_value;
        self.magnet_target[i] = no_magnet;
        self.count += 1;
        return i;
    }

    /// Remove slot `i` by moving the last live gem into it.
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
};

test "gem values follow DESIGN.md §1 and §4" {
    try std.testing.expectEqual(small_xp, gemValue(@intFromEnum(wire.EnemyArchetype.circle_t1), 0));
    try std.testing.expectEqual(small_xp, gemValue(@intFromEnum(wire.EnemyArchetype.triangle_t1), 0));
    try std.testing.expectEqual(medium_xp, gemValue(@intFromEnum(wire.EnemyArchetype.circle_t2), 0));
    try std.testing.expectEqual(large_xp, gemValue(@intFromEnum(wire.EnemyArchetype.circle_t3), 0));
    try std.testing.expectEqual(boss_cache_xp, gemValue(@intFromEnum(wire.EnemyArchetype.boss), 0));
    // An elite drops five times as much.
    try std.testing.expectEqual(small_xp * 5, gemValue(@intFromEnum(wire.EnemyArchetype.circle_t1), 1));
    try std.testing.expectEqual(large_xp * 5, gemValue(@intFromEnum(wire.EnemyArchetype.triangle_t3), 3));
}

test "a gem spawns stationary and is removed by swap" {
    var pool = Pool{};
    const a = pool.spawn(.{ 1.0, 2.0 }, small_xp).?;
    const b = pool.spawn(.{ 3.0, 4.0 }, medium_xp).?;
    const c = pool.spawn(.{ 5.0, 6.0 }, large_xp).?;
    try std.testing.expectEqual(@as(usize, 3), pool.count);
    try std.testing.expectEqual(no_magnet, pool.magnet_target[a]);
    try std.testing.expectEqual(@as(u16, small_xp), pool.xp_value[a]);
    try std.testing.expect(pool.id[a] != pool.id[b]);

    pool.swapRemove(a);
    try std.testing.expectEqual(@as(usize, 2), pool.count);
    // The last gem now occupies slot `a` with every field intact.
    try std.testing.expectEqual(pool.id[c], pool.id[a]);
    try std.testing.expectEqual([2]f32{ 5.0, 6.0 }, pool.pos[a]);
    try std.testing.expectEqual(@as(u16, large_xp), pool.xp_value[a]);
    // Slot `b` is untouched.
    try std.testing.expectEqual([2]f32{ 3.0, 4.0 }, pool.pos[b]);
}

test "a full gem pool refuses rather than overrunning" {
    var pool = Pool{};
    var i: usize = 0;
    while (i < root.max_gems) : (i += 1) {
        try std.testing.expect(pool.spawn(.{ 0.0, 0.0 }, small_xp) != null);
    }
    try std.testing.expectEqual(root.max_gems, pool.count);
    try std.testing.expect(pool.spawn(.{ 0.0, 0.0 }, small_xp) == null);
}
