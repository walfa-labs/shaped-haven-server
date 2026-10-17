//! Shaped Haven server — the phase-4 delta snapshot machinery.
//!
//! PROTOCOL.md "Full vs. delta snapshots" and "Interest management":
//!
//! * The server retains a 32-snapshot ring buffer (1.6 s of history at 20 Hz).
//!   Each slot holds the *whole* world at one snapshot tick, so any connected
//!   client can be diffed against it.
//! * A client acknowledges the tick it holds a complete state for with
//!   `C2S_ACK_SNAPSHOT`. When the next snapshot is due, the server diffs the
//!   current world against that baseline and sends `S2C_SNAPSHOT_DELTA`.
//! * A baseline of 0, or one that has fallen out of the 32-snapshot window,
//!   gets `S2C_SNAPSHOT_FULL` instead.
//! * Interest management: a snapshot — full or delta — carries only the
//!   entities within `interest_radius` of the receiving player. The diff
//!   applies that filter to both the current and the baseline world, so an
//!   entity entering the radius appears in `spawned` and one leaving it in
//!   `destroyed`.
//!
//! The diff is by entity id: an entity the baseline did not carry inside the
//! radius is `spawned`; one the current world no longer carries inside it is
//! `destroyed`; one in both whose quantized record changed is `updated`. A
//! record that did not change is not sent — the client keeps the position it
//! already has, which is exact for a stationary enemy and within one 0.05
//! quantization step for a slow one.

const std = @import("std");
const root = @import("root.zig");
const wire = @import("wire.zig");

/// Snapshots the server retains: 32, which is 1.6 s at 20 Hz (PROTOCOL.md).
pub const ring_size = 32;

/// Largest single entity kind, for the per-kind diff scratch.
const max_kind = root.max_enemies;

/// Largest total in-interest set across every kind, for the output scratch.
const max_total = root.max_enemies + root.max_projectiles + root.max_gems + root.max_players;

/// Bytes large enough to hold any net record, for the comparison scratch.
const record_bytes: usize = 16;

/// One stored snapshot: the whole world at one snapshot tick.
///
/// Only the first `counts[k]` entries of each array are meaningful; the rest are
/// stale bytes from an older, larger world and are never read.
pub const RingSlot = struct {
    tick: u32 = 0,
    /// players, enemies, projectiles, gems.
    counts: [4]u16 = @splat(0),
    players: [root.max_players]wire.PlayerNet = root.filledWithDefault(wire.PlayerNet, root.max_players),
    enemies: [root.max_enemies]wire.EnemyNet = @splat(std.mem.zeroes(wire.EnemyNet)),
    projs: [root.max_projectiles]wire.ProjNet = @splat(std.mem.zeroes(wire.ProjNet)),
    gems: [root.max_gems]wire.GemNet = @splat(std.mem.zeroes(wire.GemNet)),
};

/// The 32-snapshot history ring. Owned by the server, one per game.
///
/// The slots start zeroed (every tick 0, which is not a valid snapshot tick),
/// so a baseline lookup before anything is stored correctly finds nothing.
pub const SnapshotRing = struct {
    slots: [ring_size]RingSlot = undefined,

    /// Record the whole world at `view.server_tick`.
    ///
    /// Snapshots land every `ticks_per_snapshot` ticks, so the slot is chosen by
    /// the snapshot sequence number; a slot is overwritten every 32 snapshots,
    /// which is exactly the window a baseline can stay valid for.
    pub fn store(self: *SnapshotRing, view: wire.SnapshotView) void {
        const seq = view.server_tick / root.ticks_per_snapshot;
        var slot = &self.slots[seq % ring_size];
        slot.tick = view.server_tick;
        slot.counts = .{
            @intCast(view.players.len),
            @intCast(view.enemies.len),
            @intCast(view.projs.len),
            @intCast(view.gems.len),
        };
        @memcpy(slot.players[0..view.players.len], view.players);
        @memcpy(slot.enemies[0..view.enemies.len], view.enemies);
        @memcpy(slot.projs[0..view.projs.len], view.projs);
        @memcpy(slot.gems[0..view.gems.len], view.gems);
    }

    /// The stored snapshot for `tick`, or `null` when `tick` is 0 (no baseline
    /// yet) or has fallen out of the 32-snapshot window.
    pub fn baseline(self: *const SnapshotRing, tick: u32) ?*const RingSlot {
        if (tick == 0) return null;
        const seq = tick / root.ticks_per_snapshot;
        const slot = &self.slots[seq % ring_size];
        if (slot.tick != tick) return null;
        return slot;
    }
};

/// One destroyed entity: just its kind and id (PROTOCOL.md "Destroyed").
pub const DestroyedRef = wire.DestroyedRef;

/// Reusable scratch for one diff. The server owns one and every per-client
/// diff borrows it, so the allocation is paid once per game rather than once
/// per snapshot.
pub const DiffScratch = struct {
    /// In-interest records of one kind, from the current and the baseline world.
    cur: [max_kind]wire.DeltaRecord = undefined,
    base: [max_kind]wire.DeltaRecord = undefined,
    /// Matched flags for `base`, so a baseline record not matched by any
    /// current record is a destroy.
    base_matched: [max_kind]bool = undefined,
    /// The diff output, accumulated across kinds.
    spawned: [max_total]wire.DeltaRecord = undefined,
    updated: [max_total]wire.DeltaRecord = undefined,
    destroyed: [max_total]DestroyedRef = undefined,
    /// Holds the rotating window while `updated` is being trimmed to the
    /// per-snapshot budget. Separate from `updated` because the selection reads
    /// and writes the same array.
    selected: [max_total]wire.DeltaRecord = undefined,
    n_spawned: usize = 0,
    n_updated: usize = 0,
    n_destroyed: usize = 0,
};

/// The result of a diff: the three arrays, sliced to their counts.
pub const Delta = struct {
    spawned: []wire.DeltaRecord,
    updated: []wire.DeltaRecord,
    destroyed: []DestroyedRef,
    /// Every record the diff found changed, before the per-snapshot budget
    /// trimmed `updated`. Not a set the encoder reads — it is the measure of
    /// what the budget left out, so a caller can report the refresh latency the
    /// budget imposes.
    candidates: []wire.DeltaRecord,
    /// Updated records the per-snapshot budget could not carry. They are not
    /// lost: the rotation starts the next snapshot just past this one, so they
    /// go out next time.
    deferred: usize,
};

// ---------------------------------------------------------------------------
// Per-snapshot budget
// ---------------------------------------------------------------------------

/// Bytes a delta spends before any record: the frame header and the 37-byte
/// snapshot header.
pub const overhead_bytes: usize = wire.header_size + wire.snapshot_header_wire_size;

/// Wire cost of one `spawned` record: the kind byte and the full record.
pub fn spawnedBytes(r: wire.DeltaRecord) usize {
    return 1 + r.recordSize();
}

/// Wire cost of one `updated` record: the kind byte, the id and the record.
pub fn updatedBytes(r: wire.DeltaRecord) usize {
    return 1 + @sizeOf(u32) + r.recordSize();
}

/// Wire cost of one `destroyed` record: the kind byte and the id.
pub const destroyed_bytes: usize = 1 + @sizeOf(u32);

/// How many `updated` records one snapshot may carry, and where its window into
/// the in-interest set starts.
pub const Budget = struct {
    /// Bytes the whole frame may spend, from `root.snapshot_budget_bytes`.
    total_bytes: usize = root.snapshot_budget_bytes,
    /// Rotating start offset into the updated array. Carried per connection and
    /// advanced by however many records were actually sent, so successive
    /// snapshots tile the in-interest set instead of sending the same head of it
    /// every time and starving the tail.
    rotation: u32 = 0,
};

/// Select the updated records this snapshot can afford, in rotating order.
///
/// `spawned` and `destroyed` are correctness-critical — an entity the client
/// does not know about, or one it thinks still exists, is worse than a stale
/// position — so they are never dropped and their bytes come out of the budget
/// first. What is left pays for `updated` records, taken as one contiguous
/// window starting at `budget.rotation` and wrapping: the entities left out are
/// the ones the next snapshot starts with, so every entity in interest is
/// refreshed within `ceil(n / k)` snapshots rather than never.
///
/// Returns how many records were selected and how many were left over.
fn selectUpdated(
    updated: []wire.DeltaRecord,
    spawned: []const wire.DeltaRecord,
    destroyed: []const DestroyedRef,
    budget: Budget,
    scratch: *DiffScratch,
) struct { sent: usize, deferred: usize } {
    if (updated.len == 0) return .{ .sent = 0, .deferred = 0 };

    var spent = overhead_bytes;
    for (spawned) |r| spent += spawnedBytes(r);
    spent += destroyed.len * destroyed_bytes;

    const available = budget.total_bytes -| spent;
    const start = budget.rotation % updated.len;

    var sent: usize = 0;
    var used: usize = 0;
    while (sent < updated.len) : (sent += 1) {
        const r = updated[(start + sent) % updated.len];
        const cost = updatedBytes(r);
        // Stop at the first record that does not fit rather than skipping it:
        // the window stays contiguous, which is what makes the coverage bound
        // above hold.
        if (used + cost > available) break;
        used += cost;
        scratch.selected[sent] = r;
    }

    @memcpy(updated[0..sent], scratch.selected[0..sent]);
    return .{ .sent = sent, .deferred = updated.len - sent };
}

/// Diff the current world against a baseline, for one receiver.
///
/// `current` is the whole world at the current tick (a ring slot, stored this
/// broadcast); `baseline` is the whole world at the tick the client is expected
/// to hold. Both are filtered to the receiver's interest radius, so the delta
/// carries only the neighbourhood and the client's held state stays a faithful
/// subset of it.
pub fn computeDelta(
    current: *const RingSlot,
    baseline: *const RingSlot,
    centre: [2]f32,
    radius: f32,
    budget: Budget,
    scratch: *DiffScratch,
) Delta {
    scratch.n_spawned = 0;
    scratch.n_updated = 0;
    scratch.n_destroyed = 0;

    diffKind(wire.kind.player, current, baseline, centre, radius, scratch);
    diffKind(wire.kind.enemy, current, baseline, centre, radius, scratch);
    diffKind(wire.kind.projectile, current, baseline, centre, radius, scratch);
    diffKind(wire.kind.gem, current, baseline, centre, radius, scratch);

    const updated = scratch.updated[0..scratch.n_updated];
    const spawned = scratch.spawned[0..scratch.n_spawned];
    const destroyed = scratch.destroyed[0..scratch.n_destroyed];
    // `selectUpdated` rewrites the head of `updated` with the rotating window,
    // which is a subset of it, so the full candidate set survives the trim.
    const candidates = updated;
    const kept = selectUpdated(updated, spawned, destroyed, budget, scratch);

    return .{
        .spawned = spawned,
        .updated = updated[0..kept.sent],
        .destroyed = destroyed,
        .candidates = candidates,
        .deferred = kept.deferred,
    };
}

/// Diff one entity kind: fill the current and baseline in-interest lists, then
/// match them by id.
fn diffKind(
    comptime kind: u8,
    current: *const RingSlot,
    baseline: *const RingSlot,
    centre: [2]f32,
    radius: f32,
    scratch: *DiffScratch,
) void {
    var n_cur: usize = 0;
    var n_base: usize = 0;

    // Fill the current in-interest list.
    const cur_count = baselineCount(current, kind);
    for (0..cur_count) |i| {
        if (!inRadius(baselinePos(current, kind, i), centre, radius)) continue;
        scratch.cur[n_cur] = baselineRecord(current, kind, i);
        n_cur += 1;
    }

    // Fill the baseline in-interest list.
    const base_count = baselineCount(baseline, kind);
    for (0..base_count) |i| {
        if (!inRadius(baselinePos(baseline, kind, i), centre, radius)) continue;
        scratch.base[n_base] = baselineRecord(baseline, kind, i);
        scratch.base_matched[n_base] = false;
        n_base += 1;
    }

    // Every current entity: new, or changed against its baseline twin.
    for (scratch.cur[0..n_cur]) |c| {
        const id = c.recordId();
        var matched = false;
        for (scratch.base[0..n_base], 0..) |b, k| {
            if (b.recordId() != id) continue;
            matched = true;
            scratch.base_matched[k] = true;
            if (!recordsEqual(c, b)) {
                scratch.updated[scratch.n_updated] = c;
                scratch.n_updated += 1;
            }
            break;
        }
        if (!matched) {
            scratch.spawned[scratch.n_spawned] = c;
            scratch.n_spawned += 1;
        }
    }

    // Every baseline entity the current world did not carry is a destroy.
    for (scratch.base[0..n_base], 0..) |b, k| {
        if (scratch.base_matched[k]) continue;
        scratch.destroyed[scratch.n_destroyed] = .{ .kind = kind, .id = b.recordId() };
        scratch.n_destroyed += 1;
    }
}

// ---------------------------------------------------------------------------
// Per-kind accessors, resolved at comptime
// ---------------------------------------------------------------------------

/// How many records of `kind` the baseline holds.
fn baselineCount(baseline: *const RingSlot, comptime kind: u8) usize {
    return switch (kind) {
        wire.kind.player => baseline.counts[0],
        wire.kind.enemy => baseline.counts[1],
        wire.kind.projectile => baseline.counts[2],
        wire.kind.gem => baseline.counts[3],
        else => unreachable,
    };
}

/// The world position of record `i` of `kind` in the baseline.
fn baselinePos(baseline: *const RingSlot, comptime kind: u8, i: usize) [2]f32 {
    return switch (kind) {
        wire.kind.player => world(baseline.players[i].pos_x, baseline.players[i].pos_y),
        wire.kind.enemy => world(baseline.enemies[i].pos_x, baseline.enemies[i].pos_y),
        wire.kind.projectile => world(baseline.projs[i].pos_x, baseline.projs[i].pos_y),
        wire.kind.gem => world(baseline.gems[i].pos_x, baseline.gems[i].pos_y),
        else => unreachable,
    };
}

/// Record `i` of `kind` in the baseline as a `DeltaRecord`.
fn baselineRecord(baseline: *const RingSlot, comptime kind: u8, i: usize) wire.DeltaRecord {
    return switch (kind) {
        wire.kind.player => .{ .player = baseline.players[i] },
        wire.kind.enemy => .{ .enemy = baseline.enemies[i] },
        wire.kind.projectile => .{ .projectile = baseline.projs[i] },
        wire.kind.gem => .{ .gem = baseline.gems[i] },
        else => unreachable,
    };
}

// ---------------------------------------------------------------------------
// Geometry and comparison
// ---------------------------------------------------------------------------

/// True when the entity at `pos` is within `radius` of `centre`.
fn inRadius(pos: [2]f32, centre: [2]f32, radius: f32) bool {
    const dx = pos[0] - centre[0];
    const dy = pos[1] - centre[1];
    return dx * dx + dy * dy <= radius * radius;
}

/// Dequantize a wire position back to world units.
fn world(pos_x: i16, pos_y: i16) [2]f32 {
    return .{ wire.dequantize(pos_x), wire.dequantize(pos_y) };
}

/// True when two records of the same kind are byte-identical on the wire.
fn recordsEqual(a: wire.DeltaRecord, b: wire.DeltaRecord) bool {
    var ba: [record_bytes]u8 = undefined;
    var bb: [record_bytes]u8 = undefined;
    recordBytes(&ba, a);
    recordBytes(&bb, b);
    return std.mem.eql(u8, &ba, &bb);
}

/// Copy one net record's wire bytes into `buf`, zero-padding past its wire
/// size. The padding makes two records of the same kind comparable over a
/// fixed width.
fn recordBytes(buf: *[record_bytes]u8, r: wire.DeltaRecord) void {
    @memset(buf, 0);
    switch (r) {
        .player => |v| copyRecord(buf, v),
        .enemy => |v| copyRecord(buf, v),
        .projectile => |v| copyRecord(buf, v),
        .gem => |v| copyRecord(buf, v),
    }
}

/// Copy one packed net record's wire bytes into `buf`, trimmed to `wireSize`.
fn copyRecord(buf: *[record_bytes]u8, v: anytype) void {
    const bytes = std.mem.asBytes(&v);
    const n = wire.wireSize(@TypeOf(v));
    @memcpy(buf[0..n], bytes[0..n]);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Build a ring slot holding one enemy at `pos`, for the diff tests.
fn enemySlot(tick: u32, id: u32, pos: [2]f32) RingSlot {
    var slot = RingSlot{};
    slot.tick = tick;
    slot.counts = .{ 0, 1, 0, 0 };
    slot.enemies[0] = .{
        .id = id,
        .archetype = 1,
        .elite_mask = 0,
        .pos_x = wire.quantize(pos[0]),
        .pos_y = wire.quantize(pos[1]),
        .vel_angle = 0,
        .hp_pct = 100,
    };
    return slot;
}

test "the ring stores a snapshot and finds it as a baseline" {
    var ring = SnapshotRing{};
    const view = emptyView(30);
    ring.store(view);

    // The tick just stored is a valid baseline.
    try std.testing.expect(ring.baseline(30) != null);
    // Tick 0 is never a baseline, and one that was never stored is not either.
    try std.testing.expect(ring.baseline(0) == null);
    try std.testing.expect(ring.baseline(27) == null);
}

test "a baseline that falls out of the 32-snapshot window is refused" {
    var ring = SnapshotRing{};
    // Store a snapshot at tick 30 (sequence 10).
    var view = emptyView(30);
    ring.store(view);
    try std.testing.expect(ring.baseline(30) != null);

    // Storing 32 more snapshots overwrites the slot, so tick 30 is gone.
    var i: u32 = 0;
    while (i < ring_size) : (i += 1) {
        view.server_tick += root.ticks_per_snapshot;
        ring.store(view);
    }
    try std.testing.expect(ring.baseline(30) == null);
}

/// A budget large enough that every updated record fits, for the tests that are
/// about the diff itself rather than about the budget.
const unlimited = Budget{ .total_bytes = std.math.maxInt(usize) };

/// An empty whole-world view at `tick`, for the ring tests.
fn emptyView(tick: u32) wire.SnapshotView {
    return .{
        .server_tick = tick,
        .baseline_tick = 0,
        .run_time_ms = tick * 1000 / root.tick_hz,
        .acked_seq = std.mem.zeroes([root.max_players]u32),
        .game_state = 0,
        .counts = std.mem.zeroes([4]u16),
        .players = &.{},
        .enemies = &.{},
        .projs = &.{},
        .gems = &.{},
    };
}

test "a diff reports spawned, updated and destroyed by entity id" {
    // Baseline: enemy 1 at (10, 0), enemy 2 at (20, 0).
    var base = RingSlot{};
    base.tick = 27;
    base.counts = .{ 0, 2, 0, 0 };
    base.enemies[0] = enemySlot(0, 1, .{ 10.0, 0.0 }).enemies[0];
    base.enemies[1] = enemySlot(0, 2, .{ 20.0, 0.0 }).enemies[0];

    // Current: enemy 1 moved, enemy 2 gone, enemy 3 new.
    var cur = RingSlot{};
    cur.tick = 30;
    cur.counts = .{ 0, 2, 0, 0 };
    cur.enemies[0] = enemySlot(0, 1, .{ 11.0, 0.0 }).enemies[0]; // moved
    cur.enemies[1] = enemySlot(0, 3, .{ 30.0, 0.0 }).enemies[0]; // new

    var scratch = DiffScratch{};
    const d = computeDelta(&cur, &base, .{ 0.0, 0.0 }, 100.0, unlimited, &scratch);

    // Enemy 3 is new, enemy 2 left, enemy 1 moved.
    try std.testing.expectEqual(@as(usize, 1), d.spawned.len);
    try std.testing.expectEqual(@as(u32, 3), d.spawned[0].recordId());
    try std.testing.expectEqual(@as(usize, 1), d.updated.len);
    try std.testing.expectEqual(@as(u32, 1), d.updated[0].recordId());
    try std.testing.expectEqual(@as(usize, 1), d.destroyed.len);
    try std.testing.expectEqual(@as(u32, 2), d.destroyed[0].id);
    try std.testing.expectEqual(wire.kind.enemy, d.destroyed[0].kind);
}

test "interest management filters both sides of the diff to the radius" {
    // Baseline: enemy 1 near (10, 0), enemy 2 far (500, 0).
    var base = RingSlot{};
    base.tick = 27;
    base.counts = .{ 0, 2, 0, 0 };
    base.enemies[0] = enemySlot(0, 1, .{ 10.0, 0.0 }).enemies[0];
    base.enemies[1] = enemySlot(0, 2, .{ 500.0, 0.0 }).enemies[0];

    // Current: enemy 1 still near, enemy 2 still far, enemy 3 new and near.
    var cur = RingSlot{};
    cur.tick = 30;
    cur.counts = .{ 0, 3, 0, 0 };
    cur.enemies[0] = enemySlot(0, 1, .{ 10.5, 0.0 }).enemies[0];
    cur.enemies[1] = enemySlot(0, 2, .{ 500.0, 0.0 }).enemies[0];
    cur.enemies[2] = enemySlot(0, 3, .{ 20.0, 0.0 }).enemies[0];

    var scratch = DiffScratch{};
    // A 50-unit radius around the origin: enemy 2 is outside on both sides, so
    // it is not in the diff at all.
    const d = computeDelta(&cur, &base, .{ 0.0, 0.0 }, 50.0, unlimited, &scratch);

    // Spawned: enemy 3 (entered). Updated: enemy 1 (moved). Destroyed: none —
    // enemy 2 was never inside the radius, so it is not destroyed either.
    try std.testing.expectEqual(@as(usize, 1), d.spawned.len);
    try std.testing.expectEqual(@as(u32, 3), d.spawned[0].recordId());
    try std.testing.expectEqual(@as(usize, 1), d.updated.len);
    try std.testing.expectEqual(@as(u32, 1), d.updated[0].recordId());
    try std.testing.expectEqual(@as(usize, 0), d.destroyed.len);
}

test "an entity leaving the interest radius is destroyed" {
    // Baseline: enemy 1 near. Current: enemy 1 moved far away.
    var base = enemySlot(27, 1, .{ 10.0, 0.0 });
    var cur = enemySlot(30, 1, .{ 500.0, 0.0 });

    var scratch = DiffScratch{};
    const d = computeDelta(&cur, &base, .{ 0.0, 0.0 }, 50.0, unlimited, &scratch);

    // Enemy 1 was inside the baseline radius and is outside the current one:
    // destroyed, not updated.
    try std.testing.expectEqual(@as(usize, 0), d.spawned.len);
    try std.testing.expectEqual(@as(usize, 0), d.updated.len);
    try std.testing.expectEqual(@as(usize, 1), d.destroyed.len);
    try std.testing.expectEqual(@as(u32, 1), d.destroyed[0].id);
}

test "an unchanged record is not sent" {
    // Baseline and current hold the same enemy at the same position.
    var base = enemySlot(27, 1, .{ 10.0, 0.0 });
    var cur = enemySlot(30, 1, .{ 10.0, 0.0 });

    var scratch = DiffScratch{};
    const d = computeDelta(&cur, &base, .{ 0.0, 0.0 }, 50.0, unlimited, &scratch);

    // Nothing changed, so the delta is empty.
    try std.testing.expectEqual(@as(usize, 0), d.spawned.len);
    try std.testing.expectEqual(@as(usize, 0), d.updated.len);
    try std.testing.expectEqual(@as(usize, 0), d.destroyed.len);
}

/// A slot holding `n` enemies at `tick`, all inside the interest radius, each at
/// a distinct position offset by `shift` so a pair of these differ everywhere.
fn enemyLineSlot(tick: u32, n: usize, shift: f32) RingSlot {
    var slot = RingSlot{};
    slot.tick = tick;
    slot.counts = .{ 0, @intCast(n), 0, 0 };
    for (0..n) |i| {
        const f: f32 = @floatFromInt(i);
        slot.enemies[i] = enemySlot(0, @intCast(i + 1), .{ f + shift, shift }).enemies[0];
    }
    return slot;
}

test "the per-snapshot budget caps how many records one delta carries" {
    // 100 enemies, all moved, and a budget that pays for exactly ten of them:
    // 44 bytes of headers plus 10 x (1 kind + 4 id + 12 record).
    const n = 100;
    const base = enemyLineSlot(27, n, 0.0);
    const cur = enemyLineSlot(30, n, 1.0);

    const budget_bytes = overhead_bytes + 10 * updatedBytes(.{ .enemy = cur.enemies[0] });
    var scratch = DiffScratch{};
    const d = computeDelta(&cur, &base, .{ 0.0, 0.0 }, 1000.0, .{
        .total_bytes = budget_bytes,
    }, &scratch);

    try std.testing.expectEqual(@as(usize, 10), d.updated.len);
    try std.testing.expectEqual(@as(usize, 90), d.deferred);
    // What it did carry is within the budget, which is the whole point.
    try std.testing.expect(overhead_bytes + 10 * 17 <= budget_bytes);
}

test "the rotation refreshes every entity within a bounded number of snapshots" {
    // 100 moved enemies, a budget for 10 per snapshot, so ten snapshots must
    // cover all of them. Without the rotation the head of the list would go out
    // every time and the last ninety would never be refreshed at all.
    const n = 100;
    const base = enemyLineSlot(27, n, 0.0);
    const cur = enemyLineSlot(30, n, 1.0);
    const per_snapshot = 10;
    const budget_bytes = overhead_bytes + per_snapshot * updatedBytes(.{ .enemy = cur.enemies[0] });

    var scratch = DiffScratch{};
    var seen = std.mem.zeroes([n]bool);
    var rotation: u32 = 0;
    var snapshot: usize = 0;
    while (snapshot < 10) : (snapshot += 1) {
        const d = computeDelta(&cur, &base, .{ 0.0, 0.0 }, 1000.0, .{
            .total_bytes = budget_bytes,
            .rotation = rotation,
        }, &scratch);
        try std.testing.expectEqual(@as(usize, per_snapshot), d.updated.len);
        for (d.updated) |r| seen[r.recordId() - 1] = true;
        rotation +%= @intCast(d.updated.len);
    }

    for (seen) |s| try std.testing.expect(s);
}

test "spawned and destroyed records are never dropped to fit the budget" {
    // Baseline: enemy 1 at (10, 0), enemy 3 at (30, 0). Current: enemy 1 moved,
    // enemy 2 new, enemy 3 gone.
    var base = RingSlot{};
    base.tick = 27;
    base.counts = .{ 0, 2, 0, 0 };
    base.enemies[0] = enemySlot(0, 1, .{ 10.0, 0.0 }).enemies[0];
    base.enemies[1] = enemySlot(0, 3, .{ 30.0, 0.0 }).enemies[0];

    var cur = RingSlot{};
    cur.tick = 30;
    cur.counts = .{ 0, 2, 0, 0 };
    cur.enemies[0] = enemySlot(0, 1, .{ 11.0, 0.0 }).enemies[0];
    cur.enemies[1] = enemySlot(0, 2, .{ 20.0, 0.0 }).enemies[0];

    var scratch = DiffScratch{};
    // A budget far too small for even the headers: the correctness-critical
    // records still go, and only the update is deferred.
    const d = computeDelta(&cur, &base, .{ 0.0, 0.0 }, 50.0, .{
        .total_bytes = 1,
    }, &scratch);

    try std.testing.expectEqual(@as(usize, 1), d.spawned.len);
    try std.testing.expectEqual(@as(u32, 2), d.spawned[0].recordId());
    try std.testing.expectEqual(@as(usize, 1), d.destroyed.len);
    try std.testing.expectEqual(@as(u32, 3), d.destroyed[0].id);
    try std.testing.expectEqual(@as(usize, 0), d.updated.len);
    try std.testing.expectEqual(@as(usize, 1), d.deferred);
}
