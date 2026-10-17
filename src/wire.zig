//! Shaped Haven server — protocol v2 (protocol-v2-spec.md).
//!
//! Every packet on the wire is a 7-byte frame header followed by `payload_len`
//! bytes of payload:
//!
//! ```text
//! msg_type:    u8    @ 0
//! payload_len: u16   @ 1
//! seq:         u32   @ 3
//! payload:     [payload_len]u8 @ 7
//! ```
//!
//! The wire format is little-endian throughout. Entity records inside
//! `S2C_SNAPSHOT_FULL` are quantized per DESIGN.md §2: positions and velocities
//! are i16 in 0.05 unit steps, orientation is a u8 angle mapping 0..255 onto
//! 0..2π.
//!
//! v2 grows the player and enemy records (race, mana, dash and telegraph fields)
//! and the level-up offer (per-option stat deltas); the frame header, snapshot
//! header, projectile and gem records, and every other message are unchanged.

const std = @import("std");
const root = @import("root.zig");

comptime {
    if (@import("builtin").cpu.arch.endian() != .little)
        @compileError("wire.zig: protocol v2 is defined as little-endian");
}

/// Length in bytes of the frame header shared by every message (DESIGN.md §5).
pub const header_size: usize = 7;

/// Content size in bytes of a packed payload struct.
///
/// `@sizeOf` on a packed struct includes trailing padding up to its alignment,
/// so it over-reports by one byte for the 7-byte frame header. This measures the
/// last field's offset plus its own size instead.
pub fn wireSize(comptime T: type) usize {
    const s: std.builtin.Type.Struct = switch (@typeInfo(T)) {
        .@"struct" => |info| info,
        else => @compileError("wireSize expects a struct, got " ++ @typeName(T)),
    };
    const last = s.field_names.len - 1;
    return @offsetOf(T, s.field_names[last]) + @sizeOf(s.field_types[last]);
}

/// Maximum payload we are willing to buffer for a single incoming frame.
pub const max_payload: usize = 1 << 16;

/// Protocol version carried in `C2S_HELLO.proto_ver` (DESIGN.md §5).
pub const msg = struct {
    pub const c2s_hello: u8 = 0x01;
    pub const c2s_input: u8 = 0x02;
    pub const c2s_levelup_choice: u8 = 0x03;
    pub const c2s_ack_snapshot: u8 = 0x04;
    pub const c2s_restart: u8 = 0x05;
    pub const s2c_welcome: u8 = 0x81;
    pub const s2c_snapshot_full: u8 = 0x82;
    pub const s2c_snapshot_delta: u8 = 0x83;
    pub const s2c_levelup_offer: u8 = 0x84;
    pub const s2c_game_over: u8 = 0x85;
    pub const s2c_loadout: u8 = 0x86;
};

/// Fixed frame header (DESIGN.md §5).
pub const FrameHeader = packed struct {
    msg_type: u8,
    payload_len: u16,
    seq: u32,
};

// ---------------------------------------------------------------------------
// Client -> server payloads
// ---------------------------------------------------------------------------

/// `C2S_HELLO` payload (protocol v2).
///
/// Field order is the wire order, and the payload is always decoded field by
/// field rather than by casting the whole struct, so the name sits at offset 4
/// and the payload stays a tight 20 bytes.
///
/// ```text
/// proto_ver:          u8      @ 0   (must be 2)
/// race_id:            u8      @ 1   (0..9)
/// starting_weapon_id: u8      @ 2   (0=sword, 1=axe, 2=bow, 3=gun)
/// reserved:           u8      @ 3   (0)
/// player_name:        [16]u8  @ 4   (UTF-8, null-padded)
/// total:              20 bytes
/// ```
pub const hello_wire_size = 20;

/// In-memory form of a decoded `C2S_HELLO`.
pub const Hello = struct {
    proto_ver: u8,
    race_id: u8,
    starting_weapon_id: u8,
    reserved: u8,
    name: [16]u8,
};

/// Decode a `C2S_HELLO` payload; `null` unless exactly 20 bytes arrive.
pub fn decodeHello(bytes: []const u8) ?Hello {
    if (bytes.len != hello_wire_size) return null;
    var name: [16]u8 = undefined;
    @memcpy(&name, bytes[4..hello_wire_size]);
    return .{
        .proto_ver = bytes[0],
        .race_id = bytes[1],
        .starting_weapon_id = bytes[2],
        .reserved = bytes[3],
        .name = name,
    };
}

/// `C2S_INPUT` — 11 bytes (protocol v2).
///
/// The movement axes are analog (`-127..127`, 0 when the digital buttons are
/// used instead); `buttons` is a bitmask with the dash on bit 4. `input_seq`
/// stays in the payload for continuity with v1 — the frame header's `seq` slot
/// carries it too — and the simulation drops anything but the newest.
pub const Input = packed struct {
    input_seq: u32 = 0,
    client_tick: u32 = 0,
    buttons: u8 = 0,
    axis_x: i8 = 0,
    axis_y: i8 = 0,
};

/// `C2S_INPUT.buttons` bit layout.
pub const button = struct {
    pub const up: u8 = 0x01;
    pub const down: u8 = 0x02;
    pub const left: u8 = 0x04;
    pub const right: u8 = 0x08;
    pub const dash: u8 = 0x10;
};

/// `C2S_LEVELUP_CHOICE` — 3 bytes (PROTOCOL.md).
pub const LevelupChoice = packed struct {
    event_id: u16 = 0,
    choice_idx: u8 = 0,
};

/// `C2S_ACK_SNAPSHOT` — 4 bytes (DESIGN.md §5).
pub const AckSnapshot = packed struct {
    last_recv_server_tick: u32 = 0,
};

/// `C2S_RESTART` — empty payload (PROTOCOL.md). Asks the server for a fresh run
/// on this connection; only meaningful while `game_state` is game over.
pub const restart_wire_size = 0;

// ---------------------------------------------------------------------------
// Server -> client payloads
// ---------------------------------------------------------------------------

/// `S2C_WELCOME` — 21 bytes (PROTOCOL.md "S2C_WELCOME (0x81)").
///
/// Phase 4 grows this from 17 bytes to carry the interest radius: the client
/// needs to know how far its neighbourhood extends. `server_tick` moves from
/// offset 13 to 17, and a reserved u16 pads the layout to a 4-byte boundary.
///
/// ```text
/// player_id:        u8    @ 0
/// session_token:    u64   @ 1
/// tick_hz:          u8    @ 9   (60)
/// snap_hz:          u8    @ 10  (20)
/// arena_half_size:  u16   @ 11  (1000)
/// interest_radius:  u16   @ 13  (world units)
/// reserved:         u16   @ 15  (0)
/// server_tick:      u32   @ 17
/// total:            21 bytes
/// ```
pub const Welcome = packed struct {
    player_id: u8,
    session_token: u64,
    tick_hz: u8,
    snap_hz: u8,
    arena_half_size: u16,
    interest_radius: u16,
    reserved: u16,
    server_tick: u32,
};

/// Snapshot header (DESIGN.md §2 "Header"), 37 bytes.
///
/// Phase 1 only sends full snapshots, so `baseline_tick` is always 0 here; it
/// becomes meaningful once `S2C_SNAPSHOT_DELTA` lands in phase 4.
///
/// ```text
/// server_tick:   u32     @ 0
/// baseline_tick:   u32     @ 4
/// run_time_ms:     u32     @ 8
/// acked_seq:       [4]u32  @ 12
/// game_state:      u8      @ 28
/// counts:          [4]u16  @ 29
/// total:           37 bytes
/// ```
///
/// Encoded field by field (see `encodeSnapshotFull`) so the u8 `game_state`
/// between two wider arrays costs no padding bytes on the wire.
pub const snapshot_header_wire_size = 37;

/// Player record inside a snapshot (protocol v2 "PlayerNet", 20 bytes).
///
/// ```text
/// player_id:          u8   @ 0
/// state_flags:        u8   @ 1   (1 = ALIVE, 2 = INVULNERABLE, 4 = AWAITING_LEVELUP)
/// race_id:            u8   @ 2
/// pos_x:              i16  @ 3   0.05 unit steps
/// pos_y:              i16  @ 5
/// vel_angle:          u8   @ 7   0..255 mapping 0..2π
/// hp_pct:             u8   @ 8   hp / max_hp * 100
/// shield_pct:         u8   @ 9   shield / max_shield * 100 (0 if max_shield == 0)
/// mana_pct:           u8   @ 10  mana / max_mana * 100
/// dash_cd_remaining:  u16  @ 11  milliseconds remaining on dash cooldown
/// dash_cd_total:      u16  @ 13  total dash cooldown in milliseconds
/// is_dashing:         u8   @ 15  (1 during dash i-frames, 0 otherwise)
/// max_hp:             u16  @ 16  (for client-side HP bar)
/// max_shield:         u16  @ 18
/// total:              20 bytes
/// ```
///
/// The spec's "total: 21 bytes" line disagrees with its own field layout: the
/// v1 record's 8 bytes plus the 12 bytes these eight fields add come to 20,
/// and every offset above is explicit and contiguous. The offsets are the
/// contract; this record is 20 bytes.
pub const PlayerNet = packed struct {
    player_id: u8,
    state_flags: u8,
    race_id: u8,
    pos_x: i16,
    pos_y: i16,
    vel_angle: u8,
    hp_pct: u8,
    shield_pct: u8,
    mana_pct: u8,
    dash_cd_remaining: u16,
    dash_cd_total: u16,
    is_dashing: u8,
    max_hp: u16,
    max_shield: u16,
};

/// Enemy record inside a snapshot (protocol v2 "EnemyNet", 18 bytes).
///
/// The last six bytes are the telegraph: what the client draws as the windup
/// warning before the enemy commits to an attack.
///
/// ```text
/// id:                  u32 @ 0
/// archetype:           u8  @ 4
/// elite_mask:          u8  @ 5
/// pos_x:               i16 @ 6   0.05 unit steps
/// pos_y:               i16 @ 8
/// vel_angle:           u8  @ 10
/// hp_pct:              u8  @ 11
/// telegraph_progress:  u8  @ 12  (0 = no windup, 1..255 = windup progress)
/// telegraph_shape:     u8  @ 13  (0=None, 1=CircleAoE, 2=ConeSlash, 3=LineCharge)
/// telegraph_angle:     u16 @ 14  (facing angle in milliradians, -3142..3142)
/// telegraph_radius:    u16 @ 16  (radius for circle/cone or length for line)
/// total:               18 bytes
/// ```
pub const EnemyNet = packed struct {
    id: u32,
    archetype: u8,
    elite_mask: u8,
    pos_x: i16,
    pos_y: i16,
    vel_angle: u8,
    hp_pct: u8,
    telegraph_progress: u8,
    telegraph_shape: u8,
    telegraph_angle: u16,
    telegraph_radius: u16,
};

/// Projectile record inside a snapshot (PROTOCOL.md "ProjNet", 12 bytes).
pub const ProjNet = packed struct {
    id: u32,
    owner_id: u8,
    weapon_id: u8,
    shape: u8,
    pos_x: i16,
    pos_y: i16,
    vel_angle: u8,
};

/// XP gem record inside a snapshot (PROTOCOL.md "GemNet", 12 bytes).
pub const GemNet = packed struct {
    id: u32,
    pos_x: i16,
    pos_y: i16,
    xp_value: u16,
    magnet_target_id: u8,
    reserved: u8,
};

/// One entry of `S2C_LEVELUP_OFFER` (protocol v2 `UpgradeOptionNet`, 8 bytes).
///
/// The three fixed fields name the item; the stat fields say what the purchase
/// changes, as fixed-point values scaled by 100 so `500` reads as `5.0`. A
/// negative delta is a reduction (cooldown per level, for instance).
pub const UpgradeOptionNet = packed struct {
    item_id: u8,
    next_level: u8,
    is_evo: u8,
    stat_type: u8,
    current_stat_fp: i16,
    upgraded_stat_fp: i16,
};

/// `UpgradeOptionNet.stat_type` values.
pub const StatType = struct {
    pub const damage: u8 = 0;
    pub const armor: u8 = 1;
    pub const max_hp: u8 = 2;
    pub const move_speed: u8 = 3;
    pub const cooldown: u8 = 4;
    pub const area: u8 = 5;
    pub const projectiles: u8 = 6;
    pub const crit_chance: u8 = 7;
    pub const max_mana: u8 = 8;
    pub const max_shield: u8 = 9;
};

/// `S2C_LEVELUP_OFFER` — 29 bytes (protocol v2).
///
/// Five header bytes then three 8-byte options, written field by field (see
/// `encodeLevelupOffer`) because a packed struct cannot hold an array of
/// packed structs in this toolchain.
pub const LevelupOffer = packed struct {
    player_id: u8,
    event_id: u16,
    new_level: u16,
    opt0_item_id: u8,
    opt0_next_level: u8,
    opt0_is_evo: u8,
    opt0_stat_type: u8,
    opt0_current_stat_fp: i16,
    opt0_upgraded_stat_fp: i16,
    opt1_item_id: u8,
    opt1_next_level: u8,
    opt1_is_evo: u8,
    opt1_stat_type: u8,
    opt1_current_stat_fp: i16,
    opt1_upgraded_stat_fp: i16,
    opt2_item_id: u8,
    opt2_next_level: u8,
    opt2_is_evo: u8,
    opt2_stat_type: u8,
    opt2_current_stat_fp: i16,
    opt2_upgraded_stat_fp: i16,
};

/// `S2C_GAME_OVER` — 16 bytes (PROTOCOL.md).
pub const GameOver = packed struct {
    final_tick: u32,
    seconds_survived: u32,
    score: u32,
    kills: u32,
};

/// One weapon in `S2C_LOADOUT` (PROTOCOL.md, 3 bytes).
pub const WeaponNet = packed struct {
    item_id: u8,
    level: u8,
    evolved: u8,
};

/// One passive in `S2C_LOADOUT` (PROTOCOL.md, 2 bytes).
pub const PassiveNet = packed struct {
    item_id: u8,
    level: u8,
};

/// `S2C_LOADOUT` — 45 bytes (PROTOCOL.md).
///
/// Slots beyond `weapon_count` / `passive_count` are filled with `0xff` rather
/// than omitted, so the payload is always exactly this size. The two item
/// arrays are carried as raw bytes for the same packed-struct reason as
/// `LevelupOffer.options`.
pub const Loadout = packed struct {
    player_id: u8,
    level: u16,
    xp: u32,
    xp_next: u32,
    weapon_count: u8,
    w0_item_id: u8,
    w0_level: u8,
    w0_evolved: u8,
    w1_item_id: u8,
    w1_level: u8,
    w1_evolved: u8,
    w2_item_id: u8,
    w2_level: u8,
    w2_evolved: u8,
    w3_item_id: u8,
    w3_level: u8,
    w3_evolved: u8,
    passive_count: u8,
    p0_item_id: u8,
    p0_level: u8,
    p1_item_id: u8,
    p1_level: u8,
    p2_item_id: u8,
    p2_level: u8,
    p3_item_id: u8,
    p3_level: u8,
    p4_item_id: u8,
    p4_level: u8,
    p5_item_id: u8,
    p5_level: u8,
    p6_item_id: u8,
    p6_level: u8,
    p7_item_id: u8,
    p7_level: u8,
    p8_item_id: u8,
    p8_level: u8,
    p9_item_id: u8,
    p9_level: u8,
};

/// `EnemyNet.archetype` values.
///
/// Neither PROTOCOL.md nor DESIGN.md fixes the numbering, so this repository
/// chooses it and the client must agree: the order DESIGN.md §2 lists the
/// archetypes in, which is shape-major (every circle tier, then every triangle
/// tier, then the boss). Phase 2 emits only `circle_t1` and `triangle_t1`.
pub const EnemyArchetype = enum(u8) {
    circle_t1 = 0,
    circle_t2 = 1,
    circle_t3 = 2,
    triangle_t1 = 3,
    triangle_t2 = 4,
    triangle_t3 = 5,
    boss = 6,
};

/// `ProjNet.shape` values, in the order DESIGN.md §2 lists them.
///
/// `arc` is the instantaneous melee sweep: the damage is already applied when
/// the record is emitted, and the record exists so the client can draw the
/// swing. `circle` and `ray` are travelling projectiles that do the damage
/// themselves, on the server, as they move.
pub const ProjShape = enum(u8) {
    arc = 0,
    circle = 1,
    ray = 2,
};

/// `ProjNet.weapon_id` values, in the order DESIGN.md §3 lists the weapons.
pub const WeaponId = enum(u8) {
    sword = 0,
    axe = 1,
    bow = 2,
    gun = 3,
};

/// `EnemyNet.telegraph_shape` values.
///
/// A telegraph is the windup before an attack the client can see coming: the
/// darter's pause before its lunge and the boss's stand-still before its dash
/// are both a `line_charge`. `circle_aoe` and `cone_slash` are the shapes a
/// future telegraphed attack would use; none of the phase-1 archetypes emit
/// them yet.
pub const TelegraphShape = enum(u8) {
    none = 0,
    circle_aoe = 1,
    cone_slash = 2,
    line_charge = 3,
};

/// Quantization step for positions and velocities (DESIGN.md §2, PROTOCOL.md).
pub const quant_step: f32 = 0.05;

/// Encode a world coordinate/velocity into its i16 wire form.
pub fn quantize(value: f32) i16 {
    const scaled = @round(value / quant_step);
    return @intFromFloat(std.math.clamp(scaled, -32768.0, 32767.0));
}

/// Decode a quantized i16 wire value back into world units.
pub fn dequantize(value: i16) f32 {
    return @as(f32, @floatFromInt(value)) * quant_step;
}

/// Pack a `FrameHeader` + payload into a single little-endian buffer.
///
/// `seq` goes in the header's 4-byte slot: the server tick for
/// `S2C_SNAPSHOT_*`, the client's `input_seq` for `C2S_INPUT`, and 0
/// everywhere else (protocol v2 spec "Framing").
pub fn encodeFrame(gpa: std.mem.Allocator, msg_type: u8, payload: []const u8, seq: u32) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    try writeFrame(gpa, &out, msg_type, payload, seq);
    return out.toOwnedSlice(gpa);
}

/// Little-endian accumulator for building a payload field by field.
///
/// Entity records are appended as raw packed-struct bytes so a whole array
/// goes down in one `memcpy`. `Sink` is an unmanaged `ArrayList`, so every
/// method takes the allocator to grow it with.
pub const Sink = struct {
    out: std.ArrayList(u8),

    pub fn init() Sink {
        return .{ .out = std.ArrayList(u8).empty };
    }

    pub fn deinit(self: *Sink, gpa: std.mem.Allocator) void {
        self.out.deinit(gpa);
    }

    pub fn bytes(self: *const Sink) []const u8 {
        return self.out.items;
    }

    pub fn byte(self: *Sink, gpa: std.mem.Allocator, value: u8) !void {
        try self.out.append(gpa, value);
    }

    pub fn fixedBytes(self: *Sink, gpa: std.mem.Allocator, value: []const u8) !void {
        try self.out.appendSlice(gpa, value);
    }

    pub fn int(
        self: *Sink,
        gpa: std.mem.Allocator,
        comptime T: type,
        value: anytype,
    ) !void {
        var buffer: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
        std.mem.writeInt(std.math.ByteAlignedInt(T), &buffer, value, .little);
        try self.out.appendSlice(gpa, &buffer);
    }

    pub fn leU16(self: *Sink, gpa: std.mem.Allocator, value: anytype) !void {
        try self.int(gpa, u16, value);
    }

    pub fn leU32(self: *Sink, gpa: std.mem.Allocator, value: anytype) !void {
        try self.int(gpa, u32, value);
    }

    pub fn leU64(self: *Sink, gpa: std.mem.Allocator, value: anytype) !void {
        try self.int(gpa, u64, value);
    }

    pub fn leI16(self: *Sink, gpa: std.mem.Allocator, value: anytype) !void {
        try self.int(gpa, i16, value);
    }

    /// Append a slice of packed structs verbatim.
    ///
    /// Copied one record at a time and trimmed to `wireSize(T)`, because a
    /// packed struct's `@sizeOf` includes trailing padding that must not reach
    /// the wire.
    pub fn records(
        self: *Sink,
        gpa: std.mem.Allocator,
        comptime T: type,
        items: []const T,
    ) !void {
        if (@typeInfo(T) == .int) {
            // Plain integer arrays carry no padding, so they go down whole.
            if (items.len == 0) return;
            try self.out.appendSlice(gpa, @ptrCast(@alignCast(items)));
            return;
        }
        for (items) |item| {
            const raw: *const [@sizeOf(T)]u8 = @ptrCast(&item);
            try self.out.appendSlice(gpa, raw[0..wireSize(T)]);
        }
    }
};

/// Everything a `S2C_SNAPSHOT_FULL` payload carries, ready to encode.
pub const SnapshotView = struct {
    server_tick: u32,
    baseline_tick: u32,
    run_time_ms: u32,
    acked_seq: [root.max_players]u32,
    game_state: u8,
    /// players, enemies, projectiles, gem events (DESIGN.md §2).
    counts: [4]u16,
    players: []const PlayerNet,
    enemies: []const EnemyNet,
    projs: []const ProjNet,
    gems: []const GemNet,
};

/// Encode a full snapshot (DESIGN.md §5, message 0x82).
pub fn encodeSnapshotFull(gpa: std.mem.Allocator, view: SnapshotView) ![]u8 {
    var payload = Sink.init();
    defer payload.deinit(gpa);

    try payload.leU32(gpa, view.server_tick);
    try payload.leU32(gpa, view.baseline_tick);
    try payload.leU32(gpa, view.run_time_ms);
    try payload.records(gpa, u32, &view.acked_seq);
    try payload.byte(gpa, view.game_state);
    try payload.records(gpa, u16, &view.counts);

    try payload.records(gpa, PlayerNet, view.players);
    try payload.records(gpa, EnemyNet, view.enemies);
    try payload.records(gpa, ProjNet, view.projs);
    try payload.records(gpa, GemNet, view.gems);

    // PROTOCOL.md: `seq` carries the server tick on S2C_SNAPSHOT_*.
    return encodeFrame(gpa, msg.s2c_snapshot_full, payload.bytes(), view.server_tick);
}

// ---------------------------------------------------------------------------
// S2C_SNAPSHOT_DELTA (PROTOCOL.md "S2C_SNAPSHOT_DELTA (0x83)")
// ---------------------------------------------------------------------------

/// `kind` byte values naming the record type that follows in a delta array.
pub const kind = struct {
    pub const player: u8 = 0;
    pub const enemy: u8 = 1;
    pub const projectile: u8 = 2;
    pub const gem: u8 = 3;
};

/// One entity in a delta array: a tagged union of the four net records. The
/// entity id is the first field of every record, so `recordId` reads it back
/// without a per-kind switch.
pub const DeltaRecord = union(enum) {
    player: PlayerNet,
    enemy: EnemyNet,
    projectile: ProjNet,
    gem: GemNet,

    pub fn kindByte(r: DeltaRecord) u8 {
        return switch (r) {
            .player => kind.player,
            .enemy => kind.enemy,
            .projectile => kind.projectile,
            .gem => kind.gem,
        };
    }

    /// Wire size of the record alone (no kind byte, no id prefix).
    pub fn recordSize(r: DeltaRecord) usize {
        return switch (r) {
            .player => wireSize(PlayerNet),
            .enemy => wireSize(EnemyNet),
            .projectile => wireSize(ProjNet),
            .gem => wireSize(GemNet),
        };
    }

    /// The entity id: the first u32 of an enemy/projectile/gem record, or the
    /// player id widened to u32 for a player.
    pub fn recordId(r: DeltaRecord) u32 {
        return switch (r) {
            .player => r.player.player_id,
            .enemy => r.enemy.id,
            .projectile => r.projectile.id,
            .gem => r.gem.id,
        };
    }
};

/// One destroyed entity: just its kind and id (PROTOCOL.md "Destroyed").
pub const DestroyedRef = struct {
    kind: u8,
    id: u32,
};

/// Everything a `S2C_SNAPSHOT_DELTA` payload carries, ready to encode.
///
/// The three arrays hold `DeltaRecord` values; the encoder writes the kind
/// byte and (for updated and destroyed) the id ahead of each record.
pub const DeltaView = struct {
    server_tick: u32,
    baseline_tick: u32,
    run_time_ms: u32,
    acked_seq: [root.max_players]u32,
    game_state: u8,
    spawned: []const DeltaRecord,
    updated: []const DeltaRecord,
    destroyed: []const DestroyedRef,
};

/// Encode a delta snapshot (PROTOCOL.md "S2C_SNAPSHOT_DELTA (0x83)").
///
/// Same 37-byte header as a full snapshot, but the four counts mean spawned,
/// updated, destroyed and reserved (0), and the payload is the three arrays in
/// that order: spawned (kind + full record), updated (kind + id + full
/// record), destroyed (kind + id).
pub fn encodeSnapshotDelta(gpa: std.mem.Allocator, view: DeltaView) ![]u8 {
    var payload = Sink.init();
    defer payload.deinit(gpa);

    try payload.leU32(gpa, view.server_tick);
    try payload.leU32(gpa, view.baseline_tick);
    try payload.leU32(gpa, view.run_time_ms);
    try payload.records(gpa, u32, &view.acked_seq);
    try payload.byte(gpa, view.game_state);
    try payload.leU16(gpa, @as(u16, @intCast(view.spawned.len)));
    try payload.leU16(gpa, @as(u16, @intCast(view.updated.len)));
    try payload.leU16(gpa, @as(u16, @intCast(view.destroyed.len)));
    try payload.leU16(gpa, 0); // reserved

    for (view.spawned) |r| {
        try payload.byte(gpa, r.kindByte());
        try writeRecord(gpa, &payload, r);
    }
    for (view.updated) |r| {
        try payload.byte(gpa, r.kindByte());
        try payload.leU32(gpa, r.recordId());
        try writeRecord(gpa, &payload, r);
    }
    for (view.destroyed) |r| {
        try payload.byte(gpa, r.kind);
        try payload.leU32(gpa, r.id);
    }

    // PROTOCOL.md: `seq` carries the server tick on S2C_SNAPSHOT_*.
    return encodeFrame(gpa, msg.s2c_snapshot_delta, payload.bytes(), view.server_tick);
}

/// Append one net record's bytes to the payload, trimmed to its wire size.
fn writeRecord(gpa: std.mem.Allocator, payload: *Sink, r: DeltaRecord) !void {
    switch (r) {
        .player => |v| try writeRaw(gpa, payload, v),
        .enemy => |v| try writeRaw(gpa, payload, v),
        .projectile => |v| try writeRaw(gpa, payload, v),
        .gem => |v| try writeRaw(gpa, payload, v),
    }
}

/// Append one packed net record's wire bytes. The record is taken by value and
/// the bytes are copied out within this call, so the slice never outlives the
/// copy it points into.
fn writeRaw(gpa: std.mem.Allocator, payload: *Sink, v: anytype) !void {
    const T = @TypeOf(v);
    const raw: *const [@sizeOf(T)]u8 = @ptrCast(&v);
    try payload.fixedBytes(gpa, raw[0..wireSize(T)]);
}

/// Encode `S2C_LEVELUP_OFFER` (0x84, protocol v2): 5 header bytes then three
/// 8-byte options, 29 in total. Each option is appended through `Sink.records`,
/// which trims it to `wireSize` field by field.
pub fn encodeLevelupOffer(
    gpa: std.mem.Allocator,
    player_id: u8,
    event_id: u16,
    new_level: u16,
    options: []const UpgradeOptionNet,
) ![]u8 {
    var payload = Sink.init();
    defer payload.deinit(gpa);

    try payload.byte(gpa, player_id);
    try payload.leU16(gpa, event_id);
    try payload.leU16(gpa, new_level);
    try payload.records(gpa, UpgradeOptionNet, options);

    return encodeFrame(gpa, msg.s2c_levelup_offer, payload.bytes(), 0);
}

/// Encode `S2C_GAME_OVER` (0x85, PROTOCOL.md).
pub fn encodeGameOver(gpa: std.mem.Allocator, go: GameOver) ![]u8 {
    var payload = Sink.init();
    defer payload.deinit(gpa);

    try payload.leU32(gpa, go.final_tick);
    try payload.leU32(gpa, go.seconds_survived);
    try payload.leU32(gpa, go.score);
    try payload.leU32(gpa, go.kills);

    return encodeFrame(gpa, msg.s2c_game_over, payload.bytes(), 0);
}

/// Encode `S2C_LOADOUT` (0x86, PROTOCOL.md).
pub fn encodeLoadout(gpa: std.mem.Allocator, l: Loadout) ![]u8 {
    var payload = Sink.init();
    defer payload.deinit(gpa);

    try payload.byte(gpa, l.player_id);
    try payload.leU16(gpa, l.level);
    try payload.leU32(gpa, l.xp);
    try payload.leU32(gpa, l.xp_next);
    try payload.byte(gpa, l.weapon_count);
    try payload.byte(gpa, l.w0_item_id);
    try payload.byte(gpa, l.w0_level);
    try payload.byte(gpa, l.w0_evolved);
    try payload.byte(gpa, l.w1_item_id);
    try payload.byte(gpa, l.w1_level);
    try payload.byte(gpa, l.w1_evolved);
    try payload.byte(gpa, l.w2_item_id);
    try payload.byte(gpa, l.w2_level);
    try payload.byte(gpa, l.w2_evolved);
    try payload.byte(gpa, l.w3_item_id);
    try payload.byte(gpa, l.w3_level);
    try payload.byte(gpa, l.w3_evolved);
    try payload.byte(gpa, l.passive_count);
    try payload.byte(gpa, l.p0_item_id);
    try payload.byte(gpa, l.p0_level);
    try payload.byte(gpa, l.p1_item_id);
    try payload.byte(gpa, l.p1_level);
    try payload.byte(gpa, l.p2_item_id);
    try payload.byte(gpa, l.p2_level);
    try payload.byte(gpa, l.p3_item_id);
    try payload.byte(gpa, l.p3_level);
    try payload.byte(gpa, l.p4_item_id);
    try payload.byte(gpa, l.p4_level);
    try payload.byte(gpa, l.p5_item_id);
    try payload.byte(gpa, l.p5_level);
    try payload.byte(gpa, l.p6_item_id);
    try payload.byte(gpa, l.p6_level);
    try payload.byte(gpa, l.p7_item_id);
    try payload.byte(gpa, l.p7_level);
    try payload.byte(gpa, l.p8_item_id);
    try payload.byte(gpa, l.p8_level);
    try payload.byte(gpa, l.p9_item_id);
    try payload.byte(gpa, l.p9_level);

    return encodeFrame(gpa, msg.s2c_loadout, payload.bytes(), 0);
}

/// Append a `FrameHeader` + payload to `out`.
pub fn writeFrame(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    msg_type: u8,
    payload: []const u8,
    seq: u32,
) !void {
    var header: [header_size]u8 = undefined;
    std.mem.writeInt(u8, header[0..1], msg_type, .little);
    std.mem.writeInt(u16, header[1..3], @intCast(payload.len), .little);
    std.mem.writeInt(u32, header[3..7], seq, .little);
    try out.appendSlice(gpa, &header);
    try out.appendSlice(gpa, payload);
}

/// Read the frame header out of `bytes`; `null` if fewer than `header_size`.
pub fn decodeFrameHeader(bytes: []const u8) ?FrameHeader {
    if (bytes.len < header_size) return null;
    var copy: FrameHeader = undefined;
    const dest: [*]u8 = @ptrCast(@alignCast(&copy));
    @memcpy(dest[0..header_size], bytes[0..header_size]);
    return copy;
}

/// Read a little-endian integer of type `T` from `bytes` at `offset`.
pub fn readLe(comptime T: type, bytes: []const u8, offset: usize) T {
    const ptr: *const [@divExact(@typeInfo(T).int.bits, 8)]u8 =
        @ptrCast(@alignCast(bytes[offset..].ptr));
    return std.mem.readInt(T, ptr, .little);
}

/// Write a little-endian integer of type `T` into `bytes` at `offset`.
pub fn writeLe(comptime T: type, bytes: []u8, offset: usize, value: anytype) void {
    const ptr: *[@divExact(@typeInfo(T).int.bits, 8)]u8 =
        @ptrCast(@alignCast(bytes[offset..].ptr));
    std.mem.writeInt(T, ptr, value, .little);
}

/// Read a fixed-size packed payload struct out of `bytes`.
///
/// `null` unless the payload is exactly `wireSize(T)` long. Every payload
/// struct here is fixed size, so a longer payload is a malformed frame rather
/// than a newer version of the message: accepting it would let a peer smuggle
/// trailing bytes past the parser.
pub fn decodePayload(comptime T: type, bytes: []const u8) ?T {
    if (bytes.len != wireSize(T)) return null;
    var copy: T = undefined;
    const dest: [*]u8 = @ptrCast(@alignCast(&copy));
    @memcpy(dest[0..wireSize(T)], bytes[0..wireSize(T)]);
    return copy;
}

/// Map an angle in radians onto 0..255 (DESIGN.md §2, velocity/orientation).
pub fn angleToByte(angle_rad: f32) u8 {
    const two_pi: f32 = 6.283185307179586476925286766559;
    if (!std.math.isFinite(angle_rad)) return 0;
    const turns = @mod(angle_rad, two_pi) / two_pi;
    // Round through a wide integer and mask afterwards: rounding a turn count
    // just below one lands on exactly 256, and converting 256.0 straight to a
    // u8 is out of bounds, so the mask has to happen after the conversion.
    const scaled: i32 = @intFromFloat(@round(turns * 256.0));
    return @as(u8, @intCast(scaled & 0xff));
}

pub fn byteToAngle(angle_byte: u8) f32 {
    return @as(f32, @floatFromInt(angle_byte)) * ((2 * std.math.pi) / 256.0);
}

test "frame header is exactly 7 bytes and little-endian" {
    try std.testing.expectEqual(@as(usize, header_size), wireSize(FrameHeader));

    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    try writeFrame(std.testing.allocator, &out, msg.c2s_input, &.{}, 0);

    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0, 0, 0, 0, 0, 0 }, out.items);
}

test "encodeFrame produces header followed by payload" {
    const payload = [_]u8{ 1, 2, 3, 4 };
    const frame = try encodeFrame(std.testing.allocator, msg.s2c_welcome, &payload, 0);
    defer std.testing.allocator.free(frame);

    try std.testing.expectEqual(@as(usize, 11), frame.len);
    const header = decodeFrameHeader(frame).?;
    try std.testing.expectEqual(msg.s2c_welcome, header.msg_type);
    try std.testing.expectEqual(@as(u16, 4), header.payload_len);
    try std.testing.expectEqualSlices(u8, &payload, frame[header_size..]);
}

test "decodeFrameHeader rejects short buffers" {
    try std.testing.expect(decodeFrameHeader(&.{}) == null);
    try std.testing.expect(decodeFrameHeader(&.{ 1, 2, 3 }) == null);
    try std.testing.expect(decodeFrameHeader(&.{ 1, 2, 3, 4, 5, 6 }) == null);
    try std.testing.expect(decodeFrameHeader(&.{ 1, 2, 3, 4, 5, 6, 7 }) != null);
}

test "hello payload matches the protocol v2 field order" {
    // The name is deliberately unaligned on the wire, so the payload is
    // decoded field by field from a hand-built byte buffer.
    var raw = std.mem.zeroes([20]u8);
    raw[0] = 2; // proto_ver
    raw[1] = 3; // race_id
    raw[2] = 1; // starting_weapon_id
    raw[3] = 0; // reserved
    var abc = [_]u8{ 'a', 'b', 'c' };
    @memcpy(raw[4..7], &abc);

    const decoded = decodeHello(&raw).?;
    try std.testing.expectEqual(@as(u8, 2), decoded.proto_ver);
    try std.testing.expectEqual(@as(u8, 3), decoded.race_id);
    try std.testing.expectEqual(@as(u8, 1), decoded.starting_weapon_id);
    try std.testing.expectEqual(@as(u8, 0), decoded.reserved);
    try std.testing.expectEqualStrings("abc", decoded.name[0..3]);

    // The length must match exactly: short and over-long payloads are both
    // malformed frames.
    try std.testing.expect(decodeHello(raw[0..19]) == null);
    try std.testing.expect(decodeHello(&.{}) == null);
    var too_long = std.mem.zeroes([21]u8);
    @memcpy(too_long[0..20], &raw);
    try std.testing.expect(decodeHello(&too_long) == null);
}

test "input payload matches the protocol v2 field list" {
    try std.testing.expectEqual(@as(usize, 11), wireSize(Input));

    var payload = Sink.init();
    defer payload.deinit(std.testing.allocator);
    try payload.leU32(std.testing.allocator, 1234); // input_seq
    try payload.leU32(std.testing.allocator, 99); // client_tick
    try payload.byte(std.testing.allocator, 0x10); // buttons: dash
    try payload.byte(std.testing.allocator, @as(u8, @bitCast(@as(i8, -100)))); // axis_x
    try payload.byte(std.testing.allocator, 100); // axis_y

    const decoded = decodePayload(Input, payload.bytes()).?;
    try std.testing.expectEqual(@as(u32, 1234), decoded.input_seq);
    try std.testing.expectEqual(@as(u32, 99), decoded.client_tick);
    try std.testing.expectEqual(@as(u8, 0x10), decoded.buttons);
    try std.testing.expectEqual(@as(i8, -100), decoded.axis_x);
    try std.testing.expectEqual(@as(i8, 100), decoded.axis_y);

    // A payload that is not exactly the message size is rejected rather than
    // partially decoded.
    try std.testing.expect(decodePayload(Input, payload.bytes()[0..10]) == null);
    var too_long: [12]u8 = undefined;
    @memcpy(too_long[0..11], payload.bytes());
    too_long[11] = 0;
    try std.testing.expect(decodePayload(Input, &too_long) == null);
    try std.testing.expect(decodePayload(Input, payload.bytes()) != null);
}

test "welcome payload matches the PROTOCOL.md 21-byte layout" {
    try std.testing.expectEqual(@as(usize, 21), wireSize(Welcome));

    var payload = Sink.init();
    defer payload.deinit(std.testing.allocator);
    try payload.byte(std.testing.allocator, 2);
    try payload.leU64(std.testing.allocator, 7);
    try payload.byte(std.testing.allocator, 60);
    try payload.byte(std.testing.allocator, 20);
    try payload.leU16(std.testing.allocator, 1000);
    try payload.leU16(std.testing.allocator, 50);
    try payload.leU16(std.testing.allocator, 0);
    try payload.leU32(std.testing.allocator, 42);

    const decoded = decodePayload(Welcome, payload.bytes()).?;
    try std.testing.expectEqual(@as(u8, 2), decoded.player_id);
    try std.testing.expectEqual(@as(u8, 60), decoded.tick_hz);
    try std.testing.expectEqual(@as(u8, 20), decoded.snap_hz);
    try std.testing.expectEqual(@as(u16, 1000), decoded.arena_half_size);
    try std.testing.expectEqual(@as(u16, 50), decoded.interest_radius);
    try std.testing.expectEqual(@as(u16, 0), decoded.reserved);
    try std.testing.expectEqual(@as(u32, 42), decoded.server_tick);
}

test "a delta frame matches the PROTOCOL.md layout" {
    const gpa = std.testing.allocator;

    const spawned = [_]DeltaRecord{
        .{ .enemy = .{
            .id = 7,
            .archetype = 1,
            .elite_mask = 0,
            .pos_x = 100,
            .pos_y = -200,
            .vel_angle = 64,
            .hp_pct = 80,
            .telegraph_progress = 0,
            .telegraph_shape = 0,
            .telegraph_angle = 0,
            .telegraph_radius = 0,
        } },
    };
    const updated = [_]DeltaRecord{
        .{ .player = .{
            .player_id = 0,
            .state_flags = 1,
            .race_id = 0,
            .pos_x = 12,
            .pos_y = 34,
            .vel_angle = 0,
            .hp_pct = 100,
            .shield_pct = 0,
            .mana_pct = 0,
            .dash_cd_remaining = 0,
            .dash_cd_total = 0,
            .is_dashing = 0,
            .max_hp = 0,
            .max_shield = 0,
        } },
    };
    const destroyed = [_]DestroyedRef{
        .{ .kind = 3, .id = 9 },
    };

    const view = DeltaView{
        .server_tick = 30,
        .baseline_tick = 27,
        .run_time_ms = 500,
        .acked_seq = [_]u32{ 3, 0, 0, 0 },
        .game_state = 0,
        .spawned = &spawned,
        .updated = &updated,
        .destroyed = &destroyed,
    };
    const frame = try encodeSnapshotDelta(gpa, view);
    defer gpa.free(frame);

    const header = decodeFrameHeader(frame).?;
    try std.testing.expectEqual(msg.s2c_snapshot_delta, header.msg_type);
    try std.testing.expectEqual(@as(u32, 30), header.seq);

    // 37-byte header, then spawned (1 + 18), updated (1 + 4 + 20), destroyed (1 + 4).
    try std.testing.expectEqual(
        @as(usize, header_size + 37 + (1 + 18) + (1 + 4 + 20) + (1 + 4)),
        frame.len,
    );
    const p = frame[header_size..];
    // Header: server_tick, baseline_tick, run_time_ms, acked_seq, game_state,
    // counts = spawned, updated, destroyed, reserved.
    try std.testing.expectEqualSlices(u8, &.{
        30, 0, 0, 0, // server_tick
        27, 0, 0, 0, // baseline_tick
        244, 1, 0, 0, // run_time_ms = 500
        3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // acked_seq
        0, // game_state
        1, 0, 1, 0, 1, 0, 0, 0, // counts
    }, p[0..37]);
    // spawned[0]: kind + EnemyNet (18 bytes with the six telegraph bytes).
    try std.testing.expectEqualSlices(u8, &.{
        1, // kind = enemy
        7, 0, 0, 0, // id
        1, 0, // archetype, elite_mask
        100, 0, 56, 255, // pos_x, pos_y = -200
        64, 80, // vel_angle, hp_pct
        0, 0, 0, 0, 0, 0, // telegraph_progress/shape/angle/radius
    }, p[37..37 + 1 + 18]);
    // updated[0]: kind + id + PlayerNet (20 bytes).
    try std.testing.expectEqualSlices(u8, &.{
        0, // kind = player
        0, 0, 0, 0, // id (player_id widened)
        // player_id, state_flags, race_id
        0, 1, 0,
        12, 0, 34, 0, // pos_x, pos_y
        0, // vel_angle
        100, // hp_pct
        0, 0, // shield_pct, mana_pct
        0, 0, 0, 0, // dash_cd_remaining, dash_cd_total
        0, // is_dashing
        0, 0, 0, 0, // max_hp, max_shield
    }, p[37 + 19..37 + 19 + 1 + 4 + 20]);
    // destroyed[0]: kind + id.
    try std.testing.expectEqualSlices(u8, &.{
        3, // kind = gem
        9, 0, 0, 0, // id
    }, p[37 + 19 + 25..]);
}

test "snapshot header is 37 bytes with no padding after game_state" {
    // Built by hand so the asserted bytes are the wire format, not a struct
    // layout that could drift.
    var raw = std.mem.zeroes([snapshot_header_wire_size]u8);
    writeLe(u32, raw[0..], 0, 3);
    writeLe(u32, raw[0..], 4, 0);
    writeLe(u32, raw[0..], 8, 50);
    for ([_]u32{ 1, 2, 3, 4 }, 0..) |seq, i| {
        writeLe(u32, raw[0..], 12 + i * 4, seq);
    }
    raw[28] = 0;
    for ([_]u16{ 2, 0, 0, 0 }, 0..) |count, i| {
        writeLe(u16, raw[0..], 29 + i * 2, count);
    }

    try std.testing.expectEqualSlices(u8, &.{
        3, 0, 0, 0,
        0, 0, 0, 0,
        50, 0, 0, 0,
        1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0, 0,
        0,
        2, 0, 0, 0, 0, 0, 0, 0,
    }, &raw);
}

test "quantization round-trips at 0.05 unit granularity" {
    try std.testing.expectEqual(@as(i16, 0), quantize(0.0));
    try std.testing.expectEqual(@as(i16, 200), quantize(10.0));
    try std.testing.expectEqual(@as(i16, -20000), quantize(-1000.0));
    try std.testing.expectEqual(@as(i16, 20000), quantize(1000.0));
    try std.testing.expectEqual(@as(i16, 32767), quantize(100000.0));

    try std.testing.expectEqual(@as(f32, 0.0), dequantize(0));
    try std.testing.expectEqual(@as(f32, 10.0), dequantize(200));
    try std.testing.expectEqual(@as(f32, -1000.0), dequantize(-20000));
}

test "angle bytes wrap onto the full circle" {
    try std.testing.expectEqual(@as(u8, 0), angleToByte(0.0));
    try std.testing.expectEqual(@as(u8, 0), angleToByte(2 * std.math.pi));
    const half_pi: f32 = 1.5707963267948966;
    try std.testing.expect(@as(u8, 64) == angleToByte(half_pi) or
        @as(u8, 65) == angleToByte(half_pi));
    try std.testing.expectApproxEqAbs(half_pi, byteToAngle(64), 0.03);
}

test "angle bytes are total across the circle" {
    // `atan2` feeds every direction an enemy can face into the encoder, so no
    // in-range angle may panic. A turn count just under one rounds to 256,
    // which overflowed the u8 conversion before the mask was applied.
    try std.testing.expectEqual(@as(u8, 0), angleToByte(2 * std.math.pi - 0.0001));

    // Every degree of a full turn, negatives included, round-trips within half
    // a byte step (2π / 512 ≈ 0.012).
    const two_pi = 2 * std.math.pi;
    var degrees: i32 = -360;
    while (degrees < 360) : (degrees += 1) {
        const angle = @as(f32, @floatFromInt(degrees)) * (std.math.pi / 180.0);
        const error_rad = @abs(byteToAngle(angleToByte(angle)) - @mod(angle, two_pi));
        try std.testing.expect(error_rad < 0.05);
    }

    // A non-finite angle must not panic either.
    try std.testing.expectEqual(@as(u8, 0), angleToByte(std.math.nan(f32)));
}

test "sink encodes integers little-endian and arrays verbatim" {
    const gpa = std.testing.allocator;
    var s = Sink.init();
    defer s.deinit(gpa);

    try s.byte(gpa, 0x01);
    try s.leU16(gpa, 0x0203);
    try s.leU32(gpa, 0x04050607);
    try s.leU64(gpa, 0x08090a0b0c0d0e0f);

    try std.testing.expectEqualSlices(u8, &.{
        0x01, 0x03, 0x02, 0x07, 0x06, 0x05, 0x04,
        0x0f, 0x0e, 0x0d, 0x0c, 0x0b, 0x0a, 0x09, 0x08,
    }, s.bytes());

    var players = [_]PlayerNet{std.mem.zeroInit(PlayerNet, .{}), std.mem.zeroInit(PlayerNet, .{})};
    players[0].player_id = 1;
    players[0].state_flags = 1;
    players[0].pos_x = 200;
    players[0].vel_angle = 64;
    players[0].hp_pct = 100;
    try s.records(gpa, PlayerNet, &players);

    // 15 bytes of integers, then two 20-byte player records.
    try std.testing.expectEqual(@as(usize, 15 + 2 * 20), s.bytes().len);
    try std.testing.expectEqualSlices(u8, &.{
        1, 1, 0, 200, 0, 0, 0, 64, 100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    }, s.bytes()[15..]);
}

test "snapshot frame matches the DESIGN.md header then quantized players" {
    const gpa = std.testing.allocator;

    const players = [_]PlayerNet{
        .{
            .player_id = 0,
            .state_flags = 1,
            .race_id = 0,
            .pos_x = quantize(12.0),
            .pos_y = quantize(-4.0),
            .vel_angle = angleToByte(0.0),
            .hp_pct = 100,
            .shield_pct = 100,
            .mana_pct = 100,
            .dash_cd_remaining = 3500,
            .dash_cd_total = 3500,
            .is_dashing = 1,
            .max_hp = 110,
            .max_shield = 25,
        },
        .{
            .player_id = 1,
            .state_flags = 0,
            .race_id = 3,
            .pos_x = quantize(-40.0),
            .pos_y = quantize(20.0),
            .vel_angle = angleToByte(0.0),
            .hp_pct = 50,
            .shield_pct = 0,
            .mana_pct = 80,
            .dash_cd_remaining = 1234,
            .dash_cd_total = 2400,
            .is_dashing = 0,
            .max_hp = 75,
            .max_shield = 20,
        },
    };

    const view = SnapshotView{
        .server_tick = 6,
        .baseline_tick = 0,
        .run_time_ms = 100,
        .acked_seq = [_]u32{ 11, 0, 0, 0 },
        .game_state = 0,
        .counts = [_]u16{ 2, 0, 0, 0 },
        .players = &players,
        .enemies = &.{},
        .projs = &.{},
        .gems = &.{},
    };

    const frame = try encodeSnapshotFull(gpa, view);
    defer gpa.free(frame);

    const header = decodeFrameHeader(frame).?;
    try std.testing.expectEqual(msg.s2c_snapshot_full, header.msg_type);
    try std.testing.expectEqual(@as(u16, @intCast(frame.len - header_size)), header.payload_len);

    // SnapshotHeader (37 bytes) then two 20-byte player records.
    try std.testing.expectEqual(@as(usize, 37 + 2 * 20), frame.len - header_size);
    // `seq` carries the server tick on S2C_SNAPSHOT_* (PROTOCOL.md).
    try std.testing.expectEqual(@as(u32, 6), header.seq);
    try std.testing.expectEqualSlices(u8, &.{
        6, 0, 0, 0, // server_tick
        0, 0, 0, 0, // baseline_tick (unused in phase 1)
        100, 0, 0, 0, // run_time_ms
        11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // acked_seq
        0, // game_state
        2, 0, 0, 0, 0, 0, 0, 0, // counts
        // players[0]: id, flags, race_id, pos_x, pos_y, vel_angle, hp_pct,
        // shield_pct, mana_pct, dash_cd_remaining, dash_cd_total, is_dashing,
        // max_hp, max_shield
        0, 1, 0, 240, 0, 176, 255, 0, 100, 100, 100, 172, 13, 172, 13, 1, 110, 0, 25, 0,
        // players[1]
        1, 0, 3, 224, 252, 144, 1, 0, 50, 0, 80, 210, 4, 96, 9, 0, 75, 0, 20, 0,
    }, frame[header_size..][0..37 + 2 * 20]);
}

test "entity net records are fixed size" {
    try std.testing.expectEqual(@as(usize, 20), wireSize(PlayerNet));
    try std.testing.expectEqual(@as(usize, 18), wireSize(EnemyNet));
    try std.testing.expectEqual(@as(usize, 12), wireSize(ProjNet));
    try std.testing.expectEqual(@as(usize, 12), wireSize(GemNet));
}

test "the enum byte values PROTOCOL.md leaves open are the documented ones" {
    // These are the values the client has to agree with; changing one is a
    // protocol change, so the assertion is deliberately by number.
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(EnemyArchetype.circle_t1));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(EnemyArchetype.circle_t2));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(EnemyArchetype.circle_t3));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(EnemyArchetype.triangle_t1));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(EnemyArchetype.triangle_t2));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(EnemyArchetype.triangle_t3));
    try std.testing.expectEqual(@as(u8, 6), @intFromEnum(EnemyArchetype.boss));

    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(ProjShape.arc));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(ProjShape.circle));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(ProjShape.ray));

    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(WeaponId.sword));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(WeaponId.axe));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(WeaponId.bow));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(WeaponId.gun));
}

test "the phase-3 payload sizes match PROTOCOL.md" {
    try std.testing.expectEqual(@as(usize, 3), wireSize(LevelupChoice));
    try std.testing.expectEqual(@as(usize, 29), wireSize(LevelupOffer));
    try std.testing.expectEqual(@as(usize, 16), wireSize(GameOver));
    try std.testing.expectEqual(@as(usize, 45), wireSize(Loadout));
    try std.testing.expectEqual(@as(usize, 8), wireSize(UpgradeOptionNet));
    try std.testing.expectEqual(@as(usize, 3), wireSize(WeaponNet));
    try std.testing.expectEqual(@as(usize, 2), wireSize(PassiveNet));
}

test "the level-up offer encodes in PROTOCOL.md order" {
    const gpa = std.testing.allocator;
    const options = [_]UpgradeOptionNet{
        .{ .item_id = 0, .next_level = 2, .is_evo = 0, .stat_type = 0, .current_stat_fp = 2000, .upgraded_stat_fp = 3000 },
        .{ .item_id = 16, .next_level = 1, .is_evo = 0, .stat_type = 0, .current_stat_fp = 0, .upgraded_stat_fp = 1000 },
        .{ .item_id = 32, .next_level = 8, .is_evo = 1, .stat_type = 0, .current_stat_fp = 9000, .upgraded_stat_fp = 6500 },
    };
    const frame = try encodeLevelupOffer(gpa, 1, 7, 3, &options);
    defer gpa.free(frame);

    const header = decodeFrameHeader(frame).?;
    try std.testing.expectEqual(msg.s2c_levelup_offer, header.msg_type);
    try std.testing.expectEqual(@as(u16, 29), header.payload_len);
    try std.testing.expectEqualSlices(u8, &.{
        1, // player_id
        7, 0, // event_id
        3, 0, // new_level
        // option 0: sword level 2, damage 20.00 -> 30.00
        0, 2, 0, 0, 208, 7, 184, 11,
        // option 1: P0 level 1, damage +0.00 -> +10.00
        16, 1, 0, 0, 0, 0, 232, 3,
        // option 2: Vorpal Blender, damage 90.00 -> 65.00
        32, 8, 1, 0, 40, 35, 100, 25,
    }, frame[header_size..]);
}

test "the game-over frame encodes in PROTOCOL.md order" {
    const gpa = std.testing.allocator;
    const frame = try encodeGameOver(gpa, .{
        .final_tick = 600,
        .seconds_survived = 10,
        .score = 1234,
        .kills = 42,
    });
    defer gpa.free(frame);

    const header = decodeFrameHeader(frame).?;
    try std.testing.expectEqual(msg.s2c_game_over, header.msg_type);
    try std.testing.expectEqual(@as(u16, 16), header.payload_len);
    try std.testing.expectEqualSlices(u8, &.{
        88, 2, 0, 0, // final_tick = 600
        10, 0, 0, 0, // seconds_survived
        210, 4, 0, 0, // score
        42, 0, 0, 0, // kills
    }, frame[header_size..]);
}

test "the loadout encodes in PROTOCOL.md order and pads its slots with 0xff" {
    const gpa = std.testing.allocator;
    const frame = try encodeLoadout(gpa, .{
        .player_id = 0,
        .level = 5,
        .xp = 12,
        .xp_next = 72,
        .weapon_count = 2,
        .w0_item_id = 0, .w0_level = 8, .w0_evolved = 1,
        .w1_item_id = 3, .w1_level = 1, .w1_evolved = 0,
        .w2_item_id = 0xff, .w2_level = 0, .w2_evolved = 0,
        .w3_item_id = 0xff, .w3_level = 0, .w3_evolved = 0,
        .passive_count = 1,
        .p0_item_id = 16, .p0_level = 5,
        .p1_item_id = 0xff, .p1_level = 0,
        .p2_item_id = 0xff, .p2_level = 0,
        .p3_item_id = 0xff, .p3_level = 0,
        .p4_item_id = 0xff, .p4_level = 0,
        .p5_item_id = 0xff, .p5_level = 0,
        .p6_item_id = 0xff, .p6_level = 0,
        .p7_item_id = 0xff, .p7_level = 0,
        .p8_item_id = 0xff, .p8_level = 0,
        .p9_item_id = 0xff, .p9_level = 0,
    });
    defer gpa.free(frame);

    const header = decodeFrameHeader(frame).?;
    try std.testing.expectEqual(msg.s2c_loadout, header.msg_type);
    try std.testing.expectEqual(@as(u16, 45), header.payload_len);
    try std.testing.expectEqualSlices(u8, &.{
        0, // player_id
        5, 0, // level
        12, 0, 0, 0, // xp
        72, 0, 0, 0, // xp_next
        2, // weapon_count
        0, 8, 1, // weapons[0]: evolved sword at 8
        3, 1, 0, // weapons[1]
        0xff, 0, 0, // weapons[2]: empty
        0xff, 0, 0, // weapons[3]: empty
        1, // passive_count
        16, 5, // passives[0]
        0xff, 0, 0xff, 0, 0xff, 0, 0xff, 0, 0xff, 0, 0xff, 0, 0xff, 0, 0xff, 0, 0xff, 0,
    }, frame[header_size..]);
}
