//! Shaped Haven server — the phase-4 delta snapshot machinery.
//!
//! PROTOCOL.md "Baseline rules" and "Interest management":
//!
//! * The server retains a 32-snapshot ring buffer (1.6 s of history at 20 Hz).
//!   Each slot holds the *whole* world at one snapshot tick.
//! * Each connection also carries a model of what its client holds: a
//!   `FilteredWorld`, the receiver's own neighbourhood, entity for entity. It is
//!   built from a full snapshot, rebuilt from the ring when an acknowledgement
//!   corrects the model, and thereafter changed only by the records that
//!   actually went out — never by the ones a per-snapshot budget deferred.
//! * A snapshot is a delta against that model, or a full snapshot when there is
//!   no usable model: nothing acknowledged yet, or a tick that has fallen out of
//!   the 32-snapshot window.
//! * Interest management: a snapshot carries only the entities within
//!   `interest_radius` of the receiving player. The model is filtered around the
//!   position the player held when the snapshot it came from was built — not
//!   around wherever the player happens to be now — so an entity that entered or
//!   left the neighbourhood is reported exactly once.
//!
//! The diff is by entity id: an entity the model does not hold is `spawned`;
//! one it holds and the current neighbourhood does not is `destroyed`; one in
//! both whose quantized record changed is `updated`. A record that did not
//! change is not sent — the client keeps the position it already has, which is
//! exact for a stationary enemy and within one 0.05 quantization step for a slow
//! one.

const std = @import("std");
const root = @import("root.zig");
const wire = @import("wire.zig");

/// Snapshots the server retains: 32, which is 1.6 s at 20 Hz (PROTOCOL.md).
pub const ring_size = 32;

/// Largest single entity kind, for the per-kind match scratch.
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

/// A world filtered to one receiver's interest radius: exactly the state that
/// receiver's client holds.
///
/// The history ring stores the *whole* world at a tick; this stores only one
/// receiver's neighbourhood, and is never re-filtered. It is what a delta is
/// diffed against, which buys two things a whole-world baseline cannot:
///
/// * The baseline membership test uses the position the receiver's player held
///   when the snapshot this state came from was built, so an entity that has
///   entered or left the neighbourhood since is spawned or destroyed rather
///   than silently mistaken for one the client is known to hold.
/// * A record the per-snapshot budget deferred is simply not applied, so the
///   next diff still finds it changed and offers it again — where a baseline
///   that advanced to the snapshot's tick would treat it as delivered and never
///   resend it.
pub const FilteredWorld = struct {
    /// players, enemies, projectiles, gems.
    counts: [4]u16 = @splat(0),
    players: [root.max_players]wire.PlayerNet = root.filledWithDefault(wire.PlayerNet, root.max_players),
    enemies: [root.max_enemies]wire.EnemyNet = @splat(std.mem.zeroes(wire.EnemyNet)),
    projs: [root.max_projectiles]wire.ProjNet = @splat(std.mem.zeroes(wire.ProjNet)),
    gems: [root.max_gems]wire.GemNet = @splat(std.mem.zeroes(wire.GemNet)),

    /// Drop every entity. Only the counts are read, so the arrays are left
    /// alone rather than zeroed: this runs once per snapshot on a connection
    /// whose client has not acknowledged anything yet.
    pub fn clear(self: *FilteredWorld) void {
        self.counts = @splat(0);
    }

    /// Take the state an interest-filtered view — what a full snapshot carries —
    /// describes. A full snapshot replaces the client's state outright.
    pub fn setFromView(self: *FilteredWorld, view: wire.SnapshotView) void {
        self.counts = .{
            @intCast(view.players.len),
            @intCast(view.enemies.len),
            @intCast(view.projs.len),
            @intCast(view.gems.len),
        };
        @memcpy(self.players[0..view.players.len], view.players);
        @memcpy(self.enemies[0..view.enemies.len], view.enemies);
        @memcpy(self.projs[0..view.projs.len], view.projs);
        @memcpy(self.gems[0..view.gems.len], view.gems);
    }

    /// Rebuild from a whole-world snapshot, keeping only what lies within
    /// `radius` of `centre`. Used when an acknowledgement corrects the model to
    /// a tick the ring still holds.
    pub fn setFromSlot(
        self: *FilteredWorld,
        slot: *const RingSlot,
        centre: [2]f32,
        radius: f32,
    ) void {
        const r2 = radius * radius;
        var np: usize = 0;
        for (0..slot.counts[0]) |i| {
            if (!withinRadius(world(slot.players[i].pos_x, slot.players[i].pos_y), centre, r2)) continue;
            self.players[np] = slot.players[i];
            np += 1;
        }
        var ne: usize = 0;
        for (0..slot.counts[1]) |i| {
            if (!withinRadius(world(slot.enemies[i].pos_x, slot.enemies[i].pos_y), centre, r2)) continue;
            self.enemies[ne] = slot.enemies[i];
            ne += 1;
        }
        var nk: usize = 0;
        for (0..slot.counts[2]) |i| {
            if (!withinRadius(world(slot.projs[i].pos_x, slot.projs[i].pos_y), centre, r2)) continue;
            self.projs[nk] = slot.projs[i];
            nk += 1;
        }
        var ng: usize = 0;
        for (0..slot.counts[3]) |i| {
            if (!withinRadius(world(slot.gems[i].pos_x, slot.gems[i].pos_y), centre, r2)) continue;
            self.gems[ng] = slot.gems[i];
            ng += 1;
        }
        self.counts = .{ @intCast(np), @intCast(ne), @intCast(nk), @intCast(ng) };
    }

    /// Apply the records that actually went out. What the budget left behind is
    /// deliberately not applied: the model must describe what the client holds,
    /// not what the server meant to send.
    pub fn apply(self: *FilteredWorld, d: Delta) void {
        // Destroys first, so the arrays have room for the spawns: the two sets
        // are disjoint and together are exactly the current neighbourhood.
        for (d.destroyed) |ref| self.removeById(ref.kind, ref.id);
        for (d.spawned) |rec| self.put(rec);
        for (d.updated) |rec| self.put(rec);
    }

    fn put(self: *FilteredWorld, rec: wire.DeltaRecord) void {
        switch (rec) {
            .player => |v| putRecord(&self.counts[0], &self.players, v),
            .enemy => |v| putRecord(&self.counts[1], &self.enemies, v),
            .projectile => |v| putRecord(&self.counts[2], &self.projs, v),
            .gem => |v| putRecord(&self.counts[3], &self.gems, v),
        }
    }

    fn removeById(self: *FilteredWorld, kind: u8, id: u32) void {
        switch (kind) {
            wire.kind.player => removeRecord(&self.counts[0], &self.players, id),
            wire.kind.enemy => removeRecord(&self.counts[1], &self.enemies, id),
            wire.kind.projectile => removeRecord(&self.counts[2], &self.projs, id),
            wire.kind.gem => removeRecord(&self.counts[3], &self.gems, id),
            else => {},
        }
    }
};

/// Where a stored snapshot puts `player_id`, or `null` when it did not carry
/// that player. Quantized like every other position in the slot, to the wire's
/// 0.05-unit step.
pub fn playerPosInSlot(slot: *const RingSlot, player_id: u8) ?[2]f32 {
    for (0..slot.counts[0]) |i| {
        if (slot.players[i].player_id == player_id) {
            return world(slot.players[i].pos_x, slot.players[i].pos_y);
        }
    }
    return null;
}

/// One destroyed entity: just its kind and id (PROTOCOL.md "Destroyed").
pub const DestroyedRef = wire.DestroyedRef;

/// Reusable scratch for one diff. The server owns one and every per-client
/// diff borrows it, so the allocation is paid once per game rather than once
/// per snapshot.
pub const DiffScratch = struct {
    /// Matched flags for the model's records of one kind, so a model record no
    /// current record matched is a destroy.
    base_matched: [max_kind]bool = undefined,
    /// The diff output, accumulated across kinds.
    spawned: [max_total]wire.DeltaRecord = undefined,
    updated: [max_total]wire.DeltaRecord = undefined,
    destroyed: [max_total]DestroyedRef = undefined,
    /// Holds the rotating window while `updated` is being trimmed to the
    /// per-snapshot budget. Separate from `updated` because the selection reads
    /// and writes the same array.
    selected: [max_total]wire.DeltaRecord = undefined,
    /// The whole candidate set, copied out of `updated` before the budget trims
    /// it in place. A caller that wants to know what the budget left out — the
    /// bandwidth benchmark's refresh-latency accounting, for one — has to read
    /// this copy: after the trim, `updated` no longer holds the full set.
    candidates: [max_total]wire.DeltaRecord = undefined,
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
    /// budget imposes. A copy, not a view of `updated`.
    candidates: []wire.DeltaRecord,
    /// Updated records the per-snapshot budget could not carry. They are not
    /// lost: the model is not advanced for them, so the next diff still finds
    /// them changed and offers them again.
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
/// the candidate set starts.
pub const Budget = struct {
    /// Bytes the whole frame may spend, from `root.snapshot_budget_bytes`.
    total_bytes: usize = root.snapshot_budget_bytes,
    /// Rotating start offset into the updated array. Carried per connection and
    /// advanced by however many records were actually sent, so successive
    /// snapshots tile the candidate set instead of sending the same head of it
    /// every time and starving the tail.
    rotation: u32 = 0,
};

/// Select the updated records this snapshot can afford, in rotating order.
///
/// `spawned` and `destroyed` are correctness-critical — an entity the client
/// does not know about, or one it thinks still exists, is worse than a stale
/// position — so they are never dropped and their bytes come out of the budget
/// first. What is left pays for `updated` records, taken as one contiguous
/// window starting at `budget.rotation` and wrapping.
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
        // hold.
        if (used + cost > available) break;
        used += cost;
        scratch.selected[sent] = r;
    }

    @memcpy(updated[0..sent], scratch.selected[0..sent]);
    return .{ .sent = sent, .deferred = updated.len - sent };
}

/// Diff the current interest-filtered neighbourhood against the model of what
/// the client holds.
///
/// `current` is this receiver's neighbourhood at the current tick — already
/// filtered around where its player stands *now*. `held` is the model of the
/// client's own state, filtered around where the player stood when the snapshot
/// it came from was built. Filtering the two sides around their own centres is
/// the point: an entity that has entered the neighbourhood since the client's
/// state was captured is `spawned`, one that has left it is `destroyed`, and
/// neither is mistaken for an entity the client is already known to have.
pub fn computeDelta(
    current: wire.SnapshotView,
    held: *const FilteredWorld,
    budget: Budget,
    scratch: *DiffScratch,
) Delta {
    scratch.n_spawned = 0;
    scratch.n_updated = 0;
    scratch.n_destroyed = 0;

    diffKind(wire.kind.player, current.players, held.players[0..held.counts[0]], scratch);
    diffKind(wire.kind.enemy, current.enemies, held.enemies[0..held.counts[1]], scratch);
    diffKind(wire.kind.projectile, current.projs, held.projs[0..held.counts[2]], scratch);
    diffKind(wire.kind.gem, current.gems, held.gems[0..held.counts[3]], scratch);

    const updated = scratch.updated[0..scratch.n_updated];
    const spawned = scratch.spawned[0..scratch.n_spawned];
    const destroyed = scratch.destroyed[0..scratch.n_destroyed];
    // `selectUpdated` rewrites the head of `updated` with the rotating window,
    // so the full candidate set is copied out first — otherwise a caller reading
    // it afterwards would be reading the trimmed array.
    @memcpy(scratch.candidates[0..scratch.n_updated], updated);
    const candidates = scratch.candidates[0..scratch.n_updated];
    const kept = selectUpdated(updated, spawned, destroyed, budget, scratch);

    return .{
        .spawned = spawned,
        .updated = updated[0..kept.sent],
        .destroyed = destroyed,
        .candidates = candidates,
        .deferred = kept.deferred,
    };
}

/// Diff one entity kind: every current record against the model, then every
/// model record no current record matched.
fn diffKind(
    comptime kind: u8,
    current: anytype,
    held: anytype,
    scratch: *DiffScratch,
) void {
    @memset(scratch.base_matched[0..held.len], false);

    for (current) |c| {
        const rec = asRecord(kind, c);
        const id = rec.recordId();
        var matched = false;
        for (held, 0..) |h, k| {
            if (asRecord(kind, h).recordId() != id) continue;
            matched = true;
            scratch.base_matched[k] = true;
            if (!recordsEqual(rec, asRecord(kind, h))) {
                scratch.updated[scratch.n_updated] = rec;
                scratch.n_updated += 1;
            }
            break;
        }
        if (!matched) {
            scratch.spawned[scratch.n_spawned] = rec;
            scratch.n_spawned += 1;
        }
    }

    for (held, 0..) |h, k| {
        if (scratch.base_matched[k]) continue;
        scratch.destroyed[scratch.n_destroyed] = .{
            .kind = kind,
            .id = asRecord(kind, h).recordId(),
        };
        scratch.n_destroyed += 1;
    }
}

/// Wrap one net record of a known kind as a tagged `DeltaRecord`.
fn asRecord(comptime kind: u8, v: anytype) wire.DeltaRecord {
    return switch (kind) {
        wire.kind.player => .{ .player = v },
        wire.kind.enemy => .{ .enemy = v },
        wire.kind.projectile => .{ .projectile = v },
        wire.kind.gem => .{ .gem = v },
        else => unreachable,
    };
}

/// Replace the record for `v`'s id in `arr`, or append it when the client does
/// not hold that entity yet.
fn putRecord(count: *u16, arr: anytype, v: anytype) void {
    const id = recordId(v);
    var i: usize = 0;
    while (i < count.*) : (i += 1) {
        if (recordId(arr[i]) == id) {
            arr[i] = v;
            return;
        }
    }
    arr[count.*] = v;
    count.* += 1;
}

/// Remove the record for `id` from `arr`, by moving the last live record into
/// its place.
fn removeRecord(count: *u16, arr: anytype, id: u32) void {
    var i: usize = 0;
    while (i < count.*) : (i += 1) {
        if (recordId(arr[i]) != id) continue;
        const last = count.* - 1;
        arr[i] = arr[last];
        count.* = last;
        return;
    }
}

/// The entity id of any net record. A player's id is its own byte widened; the
/// other three carry a u32 id first.
fn recordId(v: anytype) u32 {
    return switch (@TypeOf(v)) {
        wire.PlayerNet => v.player_id,
        wire.EnemyNet, wire.ProjNet, wire.GemNet => v.id,
        else => @compileError("not a net record"),
    };
}

// ---------------------------------------------------------------------------
// Geometry and comparison
// ---------------------------------------------------------------------------

/// True when `pos` is within `radius` of `centre`, against a squared radius.
fn withinRadius(pos: [2]f32, centre: [2]f32, radius_sq: f32) bool {
    const dx = pos[0] - centre[0];
    const dy = pos[1] - centre[1];
    return dx * dx + dy * dy <= radius_sq;
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

/// A `SnapshotView` over caller-owned arrays, for the diff tests.
fn viewOf(tick: u32, enemies: []const wire.EnemyNet) wire.SnapshotView {
    return .{
        .server_tick = tick,
        .baseline_tick = 0,
        .run_time_ms = 0,
        .acked_seq = std.mem.zeroes([root.max_players]u32),
        .game_state = 0,
        .counts = .{ 0, @intCast(enemies.len), 0, 0 },
        .players = &.{},
        .enemies = enemies,
        .projs = &.{},
        .gems = &.{},
    };
}

/// One enemy record at `pos`.
fn enemyNet(id: u32, pos: [2]f32) wire.EnemyNet {
    return .{
        .id = id,
        .archetype = 1,
        .elite_mask = 0,
        .pos_x = wire.quantize(pos[0]),
        .pos_y = wire.quantize(pos[1]),
        .vel_angle = 0,
        .hp_pct = 100,
    };
}

/// `n` enemy records, all at x = `f(i)`, for the budget and rotation tests.
fn enemyLineNet(n: usize, shift: f32, out: *[max_kind]wire.EnemyNet) []const wire.EnemyNet {
    for (0..n) |i| {
        const f: f32 = @floatFromInt(i);
        out[i] = enemyNet(@intCast(i + 1), .{ f + shift, shift });
    }
    return out[0..n];
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

test "a diff reports spawned, updated and destroyed by entity id" {
    // The client holds enemy 1 at (10, 0) and enemy 2 at (20, 0).
    var held = FilteredWorld{};
    held.counts[1] = 2;
    held.enemies[0] = enemyNet(1, .{ 10.0, 0.0 });
    held.enemies[1] = enemyNet(2, .{ 20.0, 0.0 });

    // The neighbourhood now holds enemy 1 moved and enemy 3 new; enemy 2 is gone.
    const cur = [_]wire.EnemyNet{
        enemyNet(1, .{ 11.0, 0.0 }),
        enemyNet(3, .{ 30.0, 0.0 }),
    };

    var scratch = DiffScratch{};
    const d = computeDelta(viewOf(30, &cur), &held, unlimited, &scratch);

    try std.testing.expectEqual(@as(usize, 1), d.spawned.len);
    try std.testing.expectEqual(@as(u32, 3), d.spawned[0].recordId());
    try std.testing.expectEqual(@as(usize, 1), d.updated.len);
    try std.testing.expectEqual(@as(u32, 1), d.updated[0].recordId());
    try std.testing.expectEqual(@as(usize, 1), d.destroyed.len);
    try std.testing.expectEqual(@as(u32, 2), d.destroyed[0].id);
    try std.testing.expectEqual(wire.kind.enemy, d.destroyed[0].kind);
}

test "the baseline is filtered around the position the client held, not the current one" {
    // The player stood at the origin when the client's state was captured, and
    // has moved 100 units along +x since. Entity 1 sat at x = 30 — inside the
    // 40-unit radius then, 70 units away and outside it now. Entity 2 sits at
    // x = 130 — 130 units away then, 30 and inside now.
    const held_centre = [2]f32{ 0.0, 0.0 };
    const now_centre = [2]f32{ 100.0, 0.0 };
    const radius = 40.0;

    var slot = RingSlot{};
    slot.tick = 30;
    slot.counts = .{ 0, 2, 0, 0 };
    slot.enemies[0] = enemyNet(1, .{ 30.0, 0.0 });
    slot.enemies[1] = enemyNet(2, .{ 130.0, 0.0 });

    // What the client holds: filtered around where the player stood.
    var held = FilteredWorld{};
    held.setFromSlot(&slot, held_centre, radius);
    try std.testing.expectEqual(@as(u16, 1), held.counts[1]);

    // What the neighbourhood is now: filtered around where the player stands.
    var now = FilteredWorld{};
    now.setFromSlot(&slot, now_centre, radius);
    try std.testing.expectEqual(@as(u16, 1), now.counts[1]);

    var scratch = DiffScratch{};
    const d = computeDelta(
        viewOf(33, now.enemies[0..now.counts[1]]),
        &held,
        unlimited,
        &scratch,
    );

    // Entity 2 entered the neighbourhood: spawned. Entity 1 left it: destroyed.
    try std.testing.expectEqual(@as(usize, 1), d.spawned.len);
    try std.testing.expectEqual(@as(u32, 2), d.spawned[0].recordId());
    try std.testing.expectEqual(@as(usize, 1), d.destroyed.len);
    try std.testing.expectEqual(@as(u32, 1), d.destroyed[0].id);

    // Had the baseline been filtered around the *current* position instead —
    // which is what a single-centre diff does — entity 2 would look
    // already-known (no spawn) and entity 1 would not look held (no destroy):
    // the delta would be empty and the client would never learn either.
    var wrong = FilteredWorld{};
    wrong.setFromSlot(&slot, now_centre, radius);
    var scratch2 = DiffScratch{};
    const none = computeDelta(
        viewOf(33, now.enemies[0..now.counts[1]]),
        &wrong,
        unlimited,
        &scratch2,
    );
    try std.testing.expectEqual(@as(usize, 0), none.spawned.len);
    try std.testing.expectEqual(@as(usize, 0), none.destroyed.len);
}

test "an unchanged record is not sent" {
    var held = FilteredWorld{};
    held.counts[1] = 1;
    held.enemies[0] = enemyNet(1, .{ 10.0, 0.0 });

    const cur = [_]wire.EnemyNet{enemyNet(1, .{ 10.0, 0.0 })};
    var scratch = DiffScratch{};
    const d = computeDelta(viewOf(30, &cur), &held, unlimited, &scratch);

    try std.testing.expectEqual(@as(usize, 0), d.spawned.len);
    try std.testing.expectEqual(@as(usize, 0), d.updated.len);
    try std.testing.expectEqual(@as(usize, 0), d.destroyed.len);
}

test "an update the budget deferred is offered again until it goes out" {
    // The client holds enemy 1 at x = 10.
    var held = FilteredWorld{};
    held.counts[1] = 1;
    held.enemies[0] = enemyNet(1, .{ 10.0, 0.0 });

    // The enemy moves to x = 11 and then stops there: this is the state it keeps.
    const cur = [_]wire.EnemyNet{enemyNet(1, .{ 11.0, 0.0 })};

    // A budget that cannot afford even one updated record.
    const tight = Budget{ .total_bytes = overhead_bytes };

    var scratch = DiffScratch{};
    const first = computeDelta(viewOf(30, &cur), &held, tight, &scratch);
    try std.testing.expectEqual(@as(usize, 1), first.candidates.len);
    try std.testing.expectEqual(@as(usize, 0), first.updated.len);
    try std.testing.expectEqual(@as(usize, 1), first.deferred);

    // The model only takes what actually went out, so the client still holds the
    // old position.
    held.apply(first);
    try std.testing.expectEqual(wire.quantize(10.0), held.enemies[0].pos_x);

    // The enemy has not moved since, but the client has still never been told.
    // The diff must offer it again rather than treat it as delivered — which is
    // exactly what a baseline that advanced to the last snapshot's tick would
    // do, leaving the client stale forever.
    var scratch2 = DiffScratch{};
    const second = computeDelta(viewOf(33, &cur), &held, unlimited, &scratch2);
    try std.testing.expectEqual(@as(usize, 1), second.updated.len);
    try std.testing.expectEqual(@as(u32, 1), second.updated[0].recordId());
    held.apply(second);
    try std.testing.expectEqual(wire.quantize(11.0), held.enemies[0].pos_x);

    // Now the client has it, so a third diff over the same world is empty.
    var scratch3 = DiffScratch{};
    const third = computeDelta(viewOf(36, &cur), &held, unlimited, &scratch3);
    try std.testing.expectEqual(@as(usize, 0), third.updated.len);
    try std.testing.expectEqual(@as(usize, 0), third.spawned.len);
    try std.testing.expectEqual(@as(usize, 0), third.destroyed.len);
}

test "the candidate set survives the budget trim intact" {
    // 20 enemies, all moved, and a budget that pays for ten of them. The
    // candidate set the trim is measured against must still hold all twenty:
    // reading `updated` after the trim would only ever show what was sent.
    const n = 20;
    var cur_buf: [max_kind]wire.EnemyNet = undefined;
    var base_buf: [max_kind]wire.EnemyNet = undefined;
    const cur = enemyLineNet(n, 1.0, &cur_buf);
    const base = enemyLineNet(n, 0.0, &base_buf);

    var held = FilteredWorld{};
    held.counts[1] = @intCast(n);
    @memcpy(held.enemies[0..n], base);

    const budget_bytes = overhead_bytes + 10 * updatedBytes(.{ .enemy = cur[0] });
    var scratch = DiffScratch{};
    const d = computeDelta(viewOf(30, cur), &held, .{ .total_bytes = budget_bytes }, &scratch);

    try std.testing.expectEqual(@as(usize, n), d.candidates.len);
    try std.testing.expectEqual(@as(usize, 10), d.updated.len);
    try std.testing.expectEqual(@as(usize, 10), d.deferred);

    // Every candidate is a distinct entity, and the sent set is a subset of it.
    var seen = std.mem.zeroes([n]bool);
    for (d.candidates) |c| {
        const id = c.recordId();
        try std.testing.expect(!seen[id - 1]);
        seen[id - 1] = true;
    }
    for (d.updated) |u| try std.testing.expect(seen[u.recordId() - 1]);
}

test "the per-snapshot budget caps how many records one delta carries" {
    // 100 enemies, all moved, and a budget that pays for exactly ten of them:
    // 44 bytes of headers plus 10 x (1 kind + 4 id + 12 record).
    const n = 100;
    var cur_buf: [max_kind]wire.EnemyNet = undefined;
    var base_buf: [max_kind]wire.EnemyNet = undefined;
    const cur = enemyLineNet(n, 1.0, &cur_buf);
    const base = enemyLineNet(n, 0.0, &base_buf);

    var held = FilteredWorld{};
    held.counts[1] = @intCast(n);
    @memcpy(held.enemies[0..n], base);

    const budget_bytes = overhead_bytes + 10 * updatedBytes(.{ .enemy = cur[0] });
    var scratch = DiffScratch{};
    const d = computeDelta(viewOf(30, cur), &held, .{ .total_bytes = budget_bytes }, &scratch);

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
    var cur_buf: [max_kind]wire.EnemyNet = undefined;
    var base_buf: [max_kind]wire.EnemyNet = undefined;
    const cur = enemyLineNet(n, 1.0, &cur_buf);
    const base = enemyLineNet(n, 0.0, &base_buf);
    const per_snapshot = 10;
    const budget_bytes = overhead_bytes + per_snapshot * updatedBytes(.{ .enemy = cur[0] });

    var held = FilteredWorld{};
    held.counts[1] = @intCast(n);
    @memcpy(held.enemies[0..n], base);

    var scratch = DiffScratch{};
    var seen = std.mem.zeroes([n]bool);
    var rotation: u32 = 0;
    var snapshot: usize = 0;
    while (snapshot < 10) : (snapshot += 1) {
        const d = computeDelta(viewOf(30, cur), &held, .{
            .total_bytes = budget_bytes,
            .rotation = rotation,
        }, &scratch);
        try std.testing.expectEqual(@as(usize, per_snapshot), d.updated.len);
        for (d.updated) |r| seen[r.recordId() - 1] = true;
        // Only what went out is applied, so the entities still waiting stay
        // candidates for the next snapshot.
        held.apply(d);
        rotation +%= @intCast(d.updated.len);
    }

    for (seen) |s| try std.testing.expect(s);
}

test "spawned and destroyed records are never dropped to fit the budget" {
    // The client holds enemy 1 at (10, 0) and enemy 3 at (30, 0). The
    // neighbourhood now holds enemy 1 moved and enemy 2 new; enemy 3 is gone.
    var held = FilteredWorld{};
    held.counts[1] = 2;
    held.enemies[0] = enemyNet(1, .{ 10.0, 0.0 });
    held.enemies[1] = enemyNet(3, .{ 30.0, 0.0 });

    const cur = [_]wire.EnemyNet{
        enemyNet(1, .{ 11.0, 0.0 }),
        enemyNet(2, .{ 20.0, 0.0 }),
    };

    var scratch = DiffScratch{};
    // A budget far too small for even the headers: the correctness-critical
    // records still go, and only the update is deferred.
    const d = computeDelta(viewOf(30, &cur), &held, .{ .total_bytes = 1 }, &scratch);

    try std.testing.expectEqual(@as(usize, 1), d.spawned.len);
    try std.testing.expectEqual(@as(u32, 2), d.spawned[0].recordId());
    try std.testing.expectEqual(@as(usize, 1), d.destroyed.len);
    try std.testing.expectEqual(@as(u32, 3), d.destroyed[0].id);
    try std.testing.expectEqual(@as(usize, 0), d.updated.len);
    try std.testing.expectEqual(@as(usize, 1), d.deferred);
}

test "a full snapshot's view becomes exactly what the client holds" {
    // The view a full snapshot carries is the state the client ends up with, so
    // taking it as the model is what makes the next delta correct by
    // construction.
    const enemies = [_]wire.EnemyNet{
        enemyNet(7, .{ 1.0, 2.0 }),
        enemyNet(8, .{ -3.0, 4.0 }),
    };
    var held = FilteredWorld{};
    held.setFromView(viewOf(30, &enemies));

    try std.testing.expectEqual(@as(u16, 2), held.counts[1]);
    try std.testing.expectEqual(@as(u32, 7), held.enemies[0].id);
    try std.testing.expectEqual(@as(u32, 8), held.enemies[1].id);
    try std.testing.expectEqual(@as(u16, 0), held.counts[0]);
    try std.testing.expectEqual(@as(u16, 0), held.counts[2]);
    try std.testing.expectEqual(@as(u16, 0), held.counts[3]);

    // And a diff against it over the same world is empty.
    var scratch = DiffScratch{};
    const d = computeDelta(viewOf(30, &enemies), &held, unlimited, &scratch);
    try std.testing.expectEqual(@as(usize, 0), d.spawned.len);
    try std.testing.expectEqual(@as(usize, 0), d.updated.len);
    try std.testing.expectEqual(@as(usize, 0), d.destroyed.len);
}

test "applying a delta adds, replaces and removes by id" {
    var held = FilteredWorld{};
    held.counts[1] = 1;
    held.enemies[0] = enemyNet(1, .{ 10.0, 0.0 });

    var spawned = [_]wire.DeltaRecord{.{ .enemy = enemyNet(2, .{ 20.0, 0.0 }) }};
    var updated = [_]wire.DeltaRecord{.{ .enemy = enemyNet(1, .{ 11.0, 0.0 }) }};
    var destroyed = [_]DestroyedRef{.{ .kind = wire.kind.enemy, .id = 3 }};
    held.apply(.{
        .spawned = spawned[0..],
        .updated = updated[0..],
        .destroyed = destroyed[0..],
        .candidates = &.{},
        .deferred = 0,
    });

    try std.testing.expectEqual(@as(u16, 2), held.counts[1]);
    // The replaced record kept its slot; the new one was appended.
    try std.testing.expectEqual(@as(u32, 1), held.enemies[0].id);
    try std.testing.expectEqual(wire.quantize(11.0), held.enemies[0].pos_x);
    try std.testing.expectEqual(@as(u32, 2), held.enemies[1].id);

    // A destroy removes the record and the last live one takes its place.
    var held2 = FilteredWorld{};
    held2.counts[1] = 2;
    held2.enemies[0] = enemyNet(1, .{ 10.0, 0.0 });
    held2.enemies[1] = enemyNet(2, .{ 20.0, 0.0 });
    held2.apply(.{
        .spawned = &.{},
        .updated = &.{},
        .destroyed = destroyed[0..],
        .candidates = &.{},
        .deferred = 0,
    });
    try std.testing.expectEqual(@as(u16, 2), held2.counts[1]);
}
