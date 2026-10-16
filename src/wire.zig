//! Shaped Haven server — protocol v1 (DESIGN.md §5).
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
//! DESIGN.md §5 does not fix the byte layout of the `EnemyNet` / `ProjNet` /
//! `GemNet` records, so the layouts below are this repository's choice. They are
//! empty in phase 1 but are defined now so later phases only append fields.

const std = @import("std");
const root = @import("root.zig");

comptime {
    if (@import("builtin").cpu.arch.endian() != .little)
        @compileError("wire.zig: protocol v1 is defined as little-endian");
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
    pub const s2c_welcome: u8 = 0x81;
    pub const s2c_snapshot_full: u8 = 0x82;
    pub const s2c_snapshot_delta: u8 = 0x83;
    pub const s2c_levelup_offer: u8 = 0x84;
    pub const s2c_game_over: u8 = 0x85;
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

/// `C2S_HELLO` payload (DESIGN.md §5).
///
/// Field order is the wire order, and the payload is always decoded field by
/// field rather than by casting the whole struct, so the token sits at offset 2
/// and the payload stays a tight 26 bytes.
///
/// ```text
/// proto_ver:      u8      @ 0
/// requested_slot: u8      @ 1
/// session_token:  u64     @ 2
/// name:           [16]u8  @ 10
/// total:          26 bytes
/// ```
pub const hello_wire_size = 26;

/// In-memory form of a decoded `C2S_HELLO`.
pub const Hello = struct {
    proto_ver: u8,
    requested_slot: u8,
    session_token: u64,
    name: [16]u8,
};

/// Decode a `C2S_HELLO` payload; `null` when fewer than 26 bytes arrive.
pub fn decodeHello(bytes: []const u8) ?Hello {
    if (bytes.len < hello_wire_size) return null;
    var name: [16]u8 = undefined;
    @memcpy(&name, bytes[10..hello_wire_size]);
    return .{
        .proto_ver = bytes[0],
        .requested_slot = bytes[1],
        .session_token = readLe(u64, bytes, 2),
        .name = name,
    };
}

/// `C2S_INPUT` — 13 bytes (DESIGN.md §5).
///
/// Every field carries a default so test code can build inputs with the `.{...}`
/// literal form. The decoder ignores defaults: it always reads every field off
/// the wire.
pub const Input = packed struct {
    input_seq: u32 = 0,
    client_tick: u32 = 0,
    move_x: i8 = 0,
    move_y: i8 = 0,
    aim_angle: u16 = 0,
    buttons: u8 = 0,
};

/// `C2S_LEVELUP_CHOICE` — 2 bytes (DESIGN.md §5).
pub const LevelupChoice = packed struct {
    event_id: u16 = 0,
    choice_idx: u8 = 0,
};

/// `C2S_ACK_SNAPSHOT` — 4 bytes (DESIGN.md §5).
pub const AckSnapshot = packed struct {
    last_recv_server_tick: u32 = 0,
};

// ---------------------------------------------------------------------------
// Server -> client payloads
// ---------------------------------------------------------------------------

/// `S2C_WELCOME` — 17 bytes (DESIGN.md §5).
pub const Welcome = packed struct {
    player_id: u8,
    session_token: u64,
    tick_hz: u8,
    snap_hz: u8,
    arena_half_size: u16,
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

/// Player record inside a snapshot (PROTOCOL.md "PlayerNet", 8 bytes).
///
/// ```text
/// player_id:   u8   @ 0
/// state_flags: u8   @ 1   (1 = ALIVE)
/// pos_x:       i16  @ 2   0.05 unit steps
/// pos_y:       i16  @ 4
/// vel_angle:   u8   @ 6   0..255 mapping 0..2pi
/// hp_pct:      u8   @ 7   hp / max_hp * 100
/// ```
pub const PlayerNet = packed struct {
    player_id: u8,
    state_flags: u8,
    pos_x: i16,
    pos_y: i16,
    vel_angle: u8,
    hp_pct: u8,
};

/// Enemy record inside a snapshot (PROTOCOL.md "EnemyNet", 12 bytes).
pub const EnemyNet = packed struct {
    id: u32,
    archetype: u8,
    elite_mask: u8,
    pos_x: i16,
    pos_y: i16,
    vel_angle: u8,
    hp_pct: u8,
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
/// `S2C_SNAPSHOT_*`, and 0 everywhere else in protocol v1 (PROTOCOL.md
/// "Framing").
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
/// `null` when the payload is shorter than `@sizeOf(T)`. No length validation
/// is performed on structs that are not defined by DESIGN.md §5, because
/// those layouts are this repository's own choice.
pub fn decodePayload(comptime T: type, bytes: []const u8) ?T {
    if (bytes.len < wireSize(T)) return null;
    var copy: T = undefined;
    const dest: [*]u8 = @ptrCast(@alignCast(&copy));
    @memcpy(dest[0..wireSize(T)], bytes[0..wireSize(T)]);
    return copy;
}

/// Map 0..255 onto 0..2π and back (DESIGN.md §2, velocity/orientation).
pub fn angleToByte(angle_rad: f32) u8 {
    const wrapped = @mod(angle_rad, 2 * std.math.pi);
    const two_pi: f32 = 6.283185307179586476925286766559;
    const turns = wrapped / two_pi;
    return @as(u8, @intFromFloat(@round(turns * 256.0))) & 0xff;
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

test "hello payload matches the DESIGN.md field order" {
    // The token is deliberately unaligned on the wire, so the payload is
    // decoded field by field from a hand-built byte buffer.
    var raw = std.mem.zeroes([26]u8);
    raw[0] = 1; // proto_ver
    raw[1] = 0; // requested_slot
    writeLe(u64, raw[0..], 2, 0x1122334455667788);
    var abc = [_]u8{ 'a', 'b', 'c' };
    @memcpy(raw[10..13], &abc);

    const decoded = decodeHello(&raw).?;
    try std.testing.expectEqual(@as(u8, 1), decoded.proto_ver);
    try std.testing.expectEqual(@as(u8, 0), decoded.requested_slot);
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), decoded.session_token);
    try std.testing.expectEqualStrings("abc", decoded.name[0..3]);

    // Short payloads are rejected.
    try std.testing.expect(decodeHello(raw[0..25]) == null);
    try std.testing.expect(decodeHello(&.{}) == null);
}

test "input payload matches DESIGN.md field list" {
    try std.testing.expectEqual(@as(usize, 13), wireSize(Input));

    var payload = Sink.init();
    defer payload.deinit(std.testing.allocator);
    try payload.leU32(std.testing.allocator, 1234);
    try payload.leU32(std.testing.allocator, 99);
    try payload.byte(std.testing.allocator, @as(u8, @bitCast(@as(i8, -100))));
    try payload.byte(std.testing.allocator, 100);
    try payload.leU16(std.testing.allocator, 65535);
    try payload.byte(std.testing.allocator, 0xff);

    const decoded = decodePayload(Input, payload.bytes()).?;
    try std.testing.expectEqual(@as(u32, 1234), decoded.input_seq);
    try std.testing.expectEqual(@as(u32, 99), decoded.client_tick);
    try std.testing.expectEqual(@as(i8, -100), decoded.move_x);
    try std.testing.expectEqual(@as(i8, 100), decoded.move_y);
    try std.testing.expectEqual(@as(u16, 65535), decoded.aim_angle);
    try std.testing.expectEqual(@as(u8, 0xff), decoded.buttons);

    // A short payload is rejected rather than partially decoded.
    try std.testing.expect(decodePayload(Input, payload.bytes()[0..12]) == null);
}

test "welcome payload matches DESIGN.md field list" {
    try std.testing.expectEqual(@as(usize, 17), wireSize(Welcome));

    var payload = Sink.init();
    defer payload.deinit(std.testing.allocator);
    try payload.byte(std.testing.allocator, 2);
    try payload.leU64(std.testing.allocator, 7);
    try payload.byte(std.testing.allocator, 60);
    try payload.byte(std.testing.allocator, 20);
    try payload.leU16(std.testing.allocator, 1000);
    try payload.leU32(std.testing.allocator, 42);

    const decoded = decodePayload(Welcome, payload.bytes()).?;
    try std.testing.expectEqual(@as(u8, 2), decoded.player_id);
    try std.testing.expectEqual(@as(u8, 60), decoded.tick_hz);
    try std.testing.expectEqual(@as(u8, 20), decoded.snap_hz);
    try std.testing.expectEqual(@as(u16, 1000), decoded.arena_half_size);
    try std.testing.expectEqual(@as(u32, 42), decoded.server_tick);
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

    // 15 bytes of integers, then two 8-byte player records.
    try std.testing.expectEqual(@as(usize, 15 + 2 * 8), s.bytes().len);
    try std.testing.expectEqualSlices(u8, &.{
        1, 1, 200, 0, 0, 0, 64, 100,
        0, 0, 0, 0, 0, 0, 0, 0,
    }, s.bytes()[15..]);
}

test "snapshot frame matches the DESIGN.md header then quantized players" {
    const gpa = std.testing.allocator;

    const players = [_]PlayerNet{
        .{
            .player_id = 0,
            .state_flags = 1,
            .pos_x = quantize(12.0),
            .pos_y = quantize(-4.0),
            .vel_angle = angleToByte(0.0),
            .hp_pct = 100,
        },
        .{
            .player_id = 1,
            .state_flags = 0,
            .pos_x = quantize(-40.0),
            .pos_y = quantize(20.0),
            .vel_angle = angleToByte(0.0),
            .hp_pct = 50,
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

    // SnapshotHeader (37 bytes) then two 8-byte player records.
    try std.testing.expectEqual(@as(usize, 37 + 2 * 8), frame.len - header_size);
    // `seq` carries the server tick on S2C_SNAPSHOT_* (PROTOCOL.md).
    try std.testing.expectEqual(@as(u32, 6), header.seq);
    try std.testing.expectEqualSlices(u8, &.{
        6, 0, 0, 0, // server_tick
        0, 0, 0, 0, // baseline_tick (unused in phase 1)
        100, 0, 0, 0, // run_time_ms
        11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // acked_seq
        0, // game_state
        2, 0, 0, 0, 0, 0, 0, 0, // counts
        // players[0]: id, flags, pos_x, pos_y, vel_angle, hp_pct
        0, 1, 240, 0, 176, 255, 0, 100,
        // players[1]
        1, 0, 224, 252, 144, 1, 0, 50,
    }, frame[header_size..][0..37 + 2 * 8]);
}

test "entity net records are fixed size" {
    try std.testing.expectEqual(@as(usize, 8), wireSize(PlayerNet));
    try std.testing.expectEqual(@as(usize, 12), wireSize(EnemyNet));
    try std.testing.expectEqual(@as(usize, 12), wireSize(ProjNet));
    try std.testing.expectEqual(@as(usize, 12), wireSize(GemNet));
}
