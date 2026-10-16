//! Shaped Haven server — transport and the 60 Hz simulation loop.
//!
//! Threading model. The simulation is single threaded and deterministic, and it
//! never performs blocking I/O. Three kinds of threads cooperate through one
//! mutex:
//!
//! * **simulation thread** (`run`) — drains per-client input queues, advances
//!   the simulation one fixed step, and enqueues outgoing snapshot frames.
//! * **accept thread** — blocks in `net.Server.accept`, so a slow or absent
//!   client can never stall the tick loop. This is what keeps the listener
//!   non-blocking with respect to the simulation.
//! * **client I/O thread** (one per connection) — blocks in `recv`, parses
//!   frames into the input queue, and drains the output queue into `send`.
//!
//! Only the queues are shared. Each socket is owned by exactly one client I/O
//! thread and the simulation thread never touches a socket, so the lock is only
//! ever held for queue bookkeeping, never across a syscall.

const std = @import("std");
const root = @import("root.zig");
const wire = @import("wire.zig");
const sim = @import("sim.zig");
const net_opt = @import("net_opt.zig");

const net = std.Io.net;

/// Bytes requested from the socket per `recv` call on a client connection.
const read_chunk_size: usize = 4096;

/// Per-connection buffers. The write side is sized for a late-game snapshot;
/// larger frames fall back to an unbuffered writer.
const conn_read_size: usize = 16 * 1024;
const conn_write_size: usize = 64 * 1024;

/// Largest payload accepted from a client. Every protocol v1 client message is
/// far below this; the cap exists so a hostile peer cannot grow the parse
/// buffer without bound.
const max_frame_size: usize = 1024;

/// Unparsed backlog after which a connection is dropped.
const max_accum_size: usize = 1024 * 1024;

/// A connection slot that has not completed `C2S_HELLO` yet.
pub const unassigned_player: u8 = 0xff;

/// A decoded client message, queued for the simulation thread.
pub const Incoming = union(enum) {
    hello: wire.Hello,
    input: wire.Input,
    levelup_choice: wire.LevelupChoice,
    ack_snapshot: u32,
};

/// One accepted TCP connection and its parse/write state.
pub const ClientConn = struct {
    player_id: u8 = unassigned_player,
    stream: net.Stream = undefined,
    read_buf: []u8 = &.{},
    write_buf: []u8 = &.{},
    /// Raw bytes received but not yet consumed by a complete frame.
    read_accum: std.ArrayList(u8) = .empty,
    /// Parsed client messages waiting for the next simulation tick.
    incoming: std.ArrayList(Incoming) = .empty,
    /// Encoded server frames waiting to be written to the socket.
    outgoing: std.ArrayList([]const u8) = .empty,
    /// Offset of the first unparsed byte inside `read_accum`.
    accum_offset: usize = 0,
    name: [16]u8 = std.mem.zeroes([16]u8),
    session_token: u64 = 0,
    /// Last `server_tick` this client acknowledged; drives FULL vs DELTA later.
    last_recv_server_tick: u32 = 0,
    /// Set by the I/O thread once the socket is finished with.
    closed: bool = false,
    /// Set once the socket handle has been closed, so the I/O thread and
    /// `shutdown` cannot close it twice.
    stream_closed: bool = false,

    pub fn deinit(c: *ClientConn, gpa: std.mem.Allocator) void {
        c.read_accum.deinit(gpa);
        c.incoming.deinit(gpa);
        for (c.outgoing.items) |frame| gpa.free(frame);
        c.outgoing.deinit(gpa);
        gpa.free(c.read_buf);
        gpa.free(c.write_buf);
    }
};

/// A drained message together with the connection it arrived on.
const Pending = struct {
    conn: *ClientConn,
    message: Incoming,
};

pub const Server = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// Backs the slot array, so a slot keeps the same address for the whole
    /// life of a connection. Per-connection buffers and frames use `gpa`.
    arena: *std.heap.ArenaAllocator,
    sim: sim.Simulation,
    mu: std.Io.Mutex = .init,
    clients: std.ArrayList(ClientConn) = .empty,
    client_threads: std.ArrayList(std.Thread) = .empty,
    accept_thread: ?std.Thread = null,
    listener: net.Server = undefined,
    stopping: bool = false,

    pub fn init(
        io: std.Io,
        gpa: std.mem.Allocator,
        arena: *std.heap.ArenaAllocator,
    ) Server {
        return .{
            .io = io,
            .gpa = gpa,
            .arena = arena,
            .sim = sim.Simulation.init(),
        };
    }

    fn lock(self: *Server) void {
        self.mu.lock(self.io) catch {};
    }

    fn unlock(self: *Server) void {
        self.mu.unlock(self.io);
    }

    /// Bind the loopback listener and start accepting. Does not block.
    pub fn listen(self: *Server, port: u16) !void {
        var address: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(port) };
        self.listener = try net.IpAddress.listen(&address, self.io, .{
            .mode = .stream,
            .protocol = .tcp,
        });
        self.accept_thread = try std.Thread.spawn(.{}, acceptThread, .{self});
    }

    /// Stop the loop, shut the listener down, and join every thread.
    pub fn shutdown(self: *Server) void {
        self.stopping = true;

        // Wake the blocked `accept` with a throwaway connection. Closing the
        // listener out from under a pending accept makes the platform accept
        // path report a cancellation, which the standard library treats as
        // unreachable; a self-connect lets it return normally instead.
        const port = self.listener.socket.address.getPort();
        if (net.IpAddress.connect(
            &.{ .ip4 = net.Ip4Address.loopback(port) },
            self.io,
            .{ .mode = .stream, .protocol = .tcp },
        )) |wake| {
            net.Stream.close(&wake, self.io);
        } else |_| {}

        if (self.accept_thread) |thread| thread.join();
        self.accept_thread = null;
        net.Socket.close(&self.listener.socket, self.io);

        // Connection threads sit in `recv`; closing the stream is what lets
        // them observe `stopping` and return.
        self.lock();
        for (self.clients.items) |*conn| closeStream(self, conn);
        self.unlock();

        for (self.client_threads.items) |thread| thread.join();

        self.lock();
        self.client_threads.clearRetainingCapacity();
        for (self.clients.items) |*conn| conn.deinit(self.gpa);
        self.clients.clearRetainingCapacity();
        self.sim = sim.Simulation.init();
        self.unlock();
    }

    /// Run the fixed-step loop until `stopping` becomes set.
    pub fn run(self: *Server) void {
        const tick_ns: i96 = std.time.ns_per_s / root.tick_hz;
        var accumulator: i96 = 0;
        var previous = std.Io.Clock.Timestamp.now(self.io, .awake);
        var saturated_frames: u64 = 0;

        while (!self.stopping) {
            const now = std.Io.Clock.Timestamp.now(self.io, .awake);
            accumulator += previous.durationTo(now).raw.nanoseconds;
            previous = now;

            // Spiral-of-death guard: never try to run more than one second of
            // ticks in a single frame.
            if (accumulator > tick_ns * root.tick_hz) {
                accumulator = tick_ns * root.tick_hz;
                saturated_frames += 1;
                if (@mod(saturated_frames, root.tick_hz * 5) == 1) {
                    std.debug.print(
                        "[server] warning: tick loop is falling behind ({d} frames)\n",
                        .{saturated_frames},
                    );
                }
            }

            var ticks: usize = 0;
            while (accumulator >= tick_ns and ticks < root.tick_hz) {
                self.step();
                accumulator -= tick_ns;
                ticks += 1;
            }

            // Spin until the next tick deadline. A game server owns its frame
            // timing and must not hand the core to the OS scheduler: sleep
            // granularity on Windows is ~15 ms, three times a tick.
            if (accumulator > 0) {
                const deadline = std.Io.Clock.Timestamp.addDuration(previous, .{
                    .raw = .{ .nanoseconds = accumulator },
                    .clock = .awake,
                });
                while (std.Io.Clock.Timestamp.compare(
                    std.Io.Clock.Timestamp.now(self.io, .awake),
                    .lt,
                    deadline,
                )) {}
            }
        }

        if (saturated_frames > 0) {
            std.debug.print(
                "[server] tick loop saturated for {d} frames in total\n",
                .{saturated_frames},
            );
        }
    }

    /// Advance the simulation by exactly one 60 Hz step.
    pub fn step(self: *Server) void {
        // 1. Drain parsed input and apply it to the simulation, all under the
        //    lock. The lock also guards the write queue, which `handleHello`
        //    appends to, so it has to be held across dispatch.
        self.lock();
        var pending: std.ArrayList(Pending) = .empty;
        for (self.clients.items) |*conn| {
            while (conn.incoming.items.len > 0) {
                const message = conn.incoming.orderedRemove(0);
                pending.append(self.gpa, .{ .conn = conn, .message = message }) catch {};
            }
        }
        for (pending.items) |item| {
            dispatch(&self.sim, self.gpa, item.conn, item.message);
        }
        pending.deinit(self.gpa);
        self.unlock();

        // 2. Integrate.
        self.sim.advance();

        // 3. Broadcast a full snapshot at 20 Hz.
        if (self.sim.tick % root.ticks_per_snapshot == 0) {
            self.broadcast();
        }

        // 4. Push queued frames out. The connection threads only ever block in
        //    `recv`, so without this a client would sit idle waiting for a
        //    welcome that is stuck behind its own read.
        self.flushOutgoing();

        // 5. Reap connections whose I/O thread has finished.
        self.reap();
    }

    /// Write one queued frame per connection, if any is waiting.
    fn flushOutgoing(self: *Server) void {
        for (self.clients.items) |*conn| {
            if (conn.closed) continue;
            self.lock();
            const frame = if (conn.outgoing.items.len > 0)
                conn.outgoing.orderedRemove(0)
            else
                null;
            self.unlock();

            if (frame) |bytes| {
                if (!writeFrame(self.io, conn, bytes)) {
                    std.debug.print(
                        "[server] write of {d} bytes to player {d} failed\n",
                        .{ bytes.len, conn.player_id },
                    );
                    conn.closed = true;
                }
                self.gpa.free(bytes);
            }
        }
    }

    fn broadcast(self: *Server) void {
        const frame = wire.encodeSnapshotFull(self.gpa, self.sim.snapshotView()) catch {
            std.debug.print(
                "[server] error: could not encode snapshot: {s}\n",
                .{@errorName(error.OutOfMemory)},
            );
            return;
        };

        self.lock();
        defer self.unlock();
        for (self.clients.items) |*conn| {
            // A connection that has not finished its handshake has no business
            // receiving game state: the snapshot would reach the wire ahead of
            // the welcome frame.
            if (conn.closed or conn.player_id == unassigned_player) continue;
            conn.outgoing.append(self.gpa, frame) catch {
                std.debug.print(
                    "[server] error: could not queue a snapshot: {s}\n",
                    .{@errorName(error.OutOfMemory)},
                );
            };
        }
    }

    fn reap(self: *Server) void {
        self.lock();
        defer self.unlock();
        var i: usize = 0;
        while (i < self.clients.items.len) {
            if (self.clients.items[i].closed) {
                var conn = self.clients.orderedRemove(i);
                if (conn.player_id != unassigned_player) self.sim.despawnPlayer(conn.player_id);
                std.debug.print("[server] player {d} disconnected\n", .{conn.player_id});
                conn.deinit(self.gpa);
            } else {
                i += 1;
            }
        }
    }

    /// Connected sockets, for diagnostics.
    pub fn clientCount(self: *Server) usize {
        self.lock();
        defer self.unlock();
        return self.clients.items.len;
    }
};

/// Apply one queued client message to the simulation.
fn dispatch(simulation: *sim.Simulation, gpa: std.mem.Allocator, conn: *ClientConn, message: Incoming) void {
    switch (message) {
        .hello => |hello| handleHello(simulation, gpa, conn, hello),
        .input => |input| {
            if (conn.player_id != unassigned_player) simulation.applyInput(conn.player_id, input);
        },
        .levelup_choice => |choice| {
            // Consumed by the level-up engine in phase 3.
            std.debug.print(
                "[server] note: LEVELUP_CHOICE(event {d}, option {d}) is unused in phase 1\n",
                .{ choice.event_id, choice.choice_idx },
            );
        },
        .ack_snapshot => |server_tick| {
            conn.last_recv_server_tick = server_tick;
        },
    }
}

fn handleHello(simulation: *sim.Simulation, gpa: std.mem.Allocator, conn: *ClientConn, hello: wire.Hello) void {
    if (conn.player_id != unassigned_player) {
        std.debug.print("[server] note: duplicate HELLO on an assigned slot; ignored\n", .{});
        return;
    }
    if (hello.proto_ver != root.protocol_version) {
        std.debug.print(
            "[server] disconnect: proto_ver {d}, expected {d}\n",
            .{ hello.proto_ver, root.protocol_version },
        );
        conn.closed = true;
        return;
    }

    const player = simulation.spawnPlayer(hello.requested_slot) orelse {
        std.debug.print("[server] disconnect: no free player slot\n", .{});
        conn.closed = true;
        return;
    };

    conn.session_token = hello.session_token;
    conn.player_id = player.id;
    @memcpy(&conn.name, &hello.name);
    std.debug.print("[server] player {d} joined as '{s}'\n", .{ player.id, conn.name });

    // The welcome goes to this connection's own write queue, so the client I/O
    // thread can send it as soon as it gets to it.
    const welcome = welcomeFrame(gpa, conn, player.id, simulation.tick) catch |e| {
        std.debug.print("[server] welcome encode failed: {s}\n", .{@errorName(e)});
        conn.closed = true;
        return;
    };
    conn.outgoing.append(gpa, welcome) catch |e| {
        std.debug.print("[server] queue welcome failed: {s}\n", .{@errorName(e)});
        conn.closed = true;
        return;
    };

    // An immediate full snapshot, so the client need not wait 50 ms for its
    // first state.
    const snapshot = wire.encodeSnapshotFull(gpa, simulation.snapshotView()) catch |e| {
        std.debug.print("[server] snapshot encode failed: {s}\n", .{@errorName(e)});
        conn.closed = true;
        return;
    };
    conn.outgoing.append(gpa, snapshot) catch |e| {
        std.debug.print("[server] queue snapshot failed: {s}\n", .{@errorName(e)});
    };
}

fn welcomeFrame(
    gpa: std.mem.Allocator,
    conn: *ClientConn,
    player_id: u8,
    server_tick: u32,
) ![]u8 {
    var payload = wire.Sink.init();
    defer payload.deinit(gpa);

    try payload.byte(gpa, player_id);
    try payload.leU64(gpa, conn.session_token);
    try payload.byte(gpa, root.tick_hz);
    try payload.byte(gpa, root.snapshot_hz);
    try payload.leU16(gpa, @as(u16, @intFromFloat(root.arena_half_size)));
    try payload.leU32(gpa, server_tick);

    return wire.encodeFrame(gpa, wire.msg.s2c_welcome, payload.bytes(), 0);
}

/// NUL-padded `[16]u8` client name for a `C2S_HELLO`.
fn nameField(name: []const u8) [16]u8 {
    var out = std.mem.zeroes([16]u8);
    @memcpy(out[0..@min(name.len, out.len)], name);
    return out;
}

fn acceptThread(self: *Server) void {
    while (!self.stopping) {
        const stream = self.listener.accept(self.io) catch |err| switch (err) {
            // `Io.Threaded` blocks in accept, so WouldBlock is unexpected.
            error.WouldBlock => continue,
            else => {
                std.debug.print(
                    "[server] accept failed: {s}; listener stopped\n",
                    .{@errorName(err)},
                );
                return;
            },
        };

        if (self.stopping) {
            net.Stream.close(&stream, self.io);
            return;
        }

        registerClient(self, stream) catch |err| {
            std.debug.print("[server] dropping connection: {s}\n", .{@errorName(err)});
            net.Stream.close(&stream, self.io);
        };
    }
}

fn registerClient(self: *Server, stream: net.Stream) !void {
    const read_buf = try self.gpa.alloc(u8, conn_read_size);
    errdefer self.gpa.free(read_buf);
    const write_buf = try self.gpa.alloc(u8, conn_write_size);
    errdefer self.gpa.free(write_buf);

    const conn: ClientConn = .{
        .stream = stream,
        .read_buf = read_buf,
        .write_buf = write_buf,
    };

    self.lock();
    defer self.unlock();

    try self.clients.append(self.arena.allocator(), conn);
    const slot = self.clients.items.len - 1;

    const thread = std.Thread.spawn(.{}, clientThread, .{self, &self.clients.items[slot]}) catch {
        _ = self.clients.orderedRemove(slot);
        return error.ThreadSpawnFailed;
    };
    try self.client_threads.append(self.arena.allocator(), thread);
}

fn clientThread(self: *Server, conn: *ClientConn) void {
    var chunk: [read_chunk_size]u8 = undefined;
    var buffers: [1][]u8 = [_][]u8{chunk[0..]};

    while (!self.stopping and !conn.closed) {
        const n = net.Stream.read(&conn.stream, self.io, &buffers) catch break;
        if (n == 0) break; // peer closed the connection

        if (!accumulateAndParse(self, conn, chunk[0..n])) break;
    }

    // Send whatever is still queued, then retire the connection.
    if (!drainOutgoing(self, conn)) conn.closed = true;

    self.lock();
    closeStream(self, conn);
    conn.closed = true;
    self.unlock();
}

/// Close a connection's socket exactly once. The caller must hold the lock:
/// `shutdown` closes every live stream to wake the blocked `recv`, and the
/// connection thread closes its own on the way out.
fn closeStream(self: *Server, conn: *ClientConn) void {
    if (conn.stream_closed) return;
    conn.stream_closed = true;
    net.Stream.close(&conn.stream, self.io);
}

/// Pop every queued frame and write it to the socket. Returns `false` if a
/// write failed, in which case the connection is dead.
fn drainOutgoing(self: *Server, conn: *ClientConn) bool {
    while (true) {
        self.lock();
        const frame = if (conn.outgoing.items.len > 0)
            conn.outgoing.orderedRemove(0)
        else
            null;
        self.unlock();

        if (frame == null) return true;
        const bytes: []const u8 = frame.?;
        if (!writeFrame(self.io, conn, bytes)) {
            self.gpa.free(bytes);
            return false;
        }
        self.gpa.free(bytes);
    }
}

fn writeFrame(io: std.Io, conn: *ClientConn, frame: []const u8) bool {
    if (frame.len == 0) return true;

    // The frame travels as `data` through an unbuffered writer. A writer
    // handed a non-empty buffer plus empty data takes a different AFD SEND
    // path that does not deliver, so the buffer is always empty here.
    var writer = net.Stream.writer(conn.stream, io, conn.write_buf[0..0]);
    if (writer.interface.writeAll(frame)) {
        if (std.Io.Writer.flush(&writer.interface)) {
            return true;
        } else |_| {
            return false;
        }
    } else |_| {
        return false;
    }
}

/// Append received bytes to the parse buffer and queue every complete frame.
/// Returns `false` when the connection should be dropped.
fn accumulateAndParse(self: *Server, conn: *ClientConn, bytes: []const u8) bool {
    const gpa = self.gpa;

    if (conn.read_accum.items.len - conn.accum_offset + bytes.len > max_accum_size) {
        std.debug.print(
            "[server] disconnect: unparsed backlog reached {d} bytes\n",
            .{max_accum_size},
        );
        return false;
    }

    conn.read_accum.appendSlice(gpa, bytes) catch {
        std.debug.print("[server] disconnect: out of memory while parsing\n", .{});
        return false;
    };

    var pending = conn.read_accum.items[conn.accum_offset..];
    var consumed: usize = 0;
    while (pending.len >= wire.header_size) {
        const header = wire.decodeFrameHeader(pending).?;
        if (header.payload_len > max_frame_size) {
            std.debug.print(
                "[server] disconnect: payload of {d} bytes exceeds the limit\n",
                .{header.payload_len},
            );
            return false;
        }
        const total: usize = wire.header_size + header.payload_len;
        if (pending.len < total) break;
        routeClient(self, conn, header.msg_type, pending[wire.header_size..total]);
        consumed += total;
        pending = pending[total..];
    }
    conn.accum_offset += consumed;

    // Compact once the parsed prefix is a large share of the buffer.
    if (conn.accum_offset > conn_read_size / 2 and
        conn.accum_offset * 2 >= conn.read_accum.items.len)
    {
        const kept = conn.read_accum.items.len - conn.accum_offset;
        std.mem.copyForwards(
            u8,
            conn.read_accum.items[0..kept],
            conn.read_accum.items[conn.accum_offset..],
        );
        conn.read_accum.shrinkRetainingCapacity(kept);
        conn.accum_offset = 0;
    }
    return true;
}

fn routeClient(self: *Server, conn: *ClientConn, msg_type: u8, payload: []const u8) void {
    switch (msg_type) {
        wire.msg.c2s_hello => {
            const hello = wire.decodeHello(payload) orelse return;
            self.lock();
            defer self.unlock();
            dispatch(&self.sim, self.gpa, conn, .{ .hello = hello });
        },
        wire.msg.c2s_input => {
            const input = wire.decodePayload(wire.Input, payload) orelse return;
            self.lock();
            defer self.unlock();
            conn.incoming.append(self.gpa, .{ .input = input }) catch {};
        },
        wire.msg.c2s_levelup_choice => {
            const choice = wire.decodePayload(wire.LevelupChoice, payload) orelse return;
            self.lock();
            defer self.unlock();
            dispatch(&self.sim, self.gpa, conn, .{ .levelup_choice = choice });
        },
        wire.msg.c2s_ack_snapshot => {
            const ack = wire.decodePayload(wire.AckSnapshot, payload) orelse return;
            self.lock();
            defer self.unlock();
            conn.incoming.append(
                self.gpa,
                .{ .ack_snapshot = ack.last_recv_server_tick },
            ) catch {};
        },
        else => std.debug.print(
            "[server] note: ignoring unknown message type 0x{x}\n",
            .{msg_type},
        ),
    }
}

test "frame parser splits concatenated client messages" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var server = Server.init(std.Io.failing, gpa, &arena);

    var payload = wire.Sink.init();
    defer payload.deinit(gpa);
    try payload.leU32(gpa, 1); // input_seq
    try payload.leU32(gpa, 2); // client_tick
    try payload.byte(gpa, @as(u8, @bitCast(@as(i8, 100)))); // move_x
    try payload.byte(gpa, 0); // move_y
    try payload.leU16(gpa, 0); // aim_angle
    try payload.byte(gpa, 0); // buttons

    var wire_bytes = std.ArrayList(u8).empty;
    defer wire_bytes.deinit(gpa);
    try wire.writeFrame(gpa, &wire_bytes, wire.msg.c2s_input, payload.bytes(), 0);
    try wire.writeFrame(gpa, &wire_bytes, wire.msg.c2s_input, payload.bytes(), 0);

    var conn = ClientConn{};
    try std.testing.expect(accumulateAndParse(&server, &conn, wire_bytes.items));

    try std.testing.expectEqual(@as(usize, 2), conn.incoming.items.len);
    const first = conn.incoming.items[0].input;
    try std.testing.expectEqual(@as(u32, 1), first.input_seq);
    try std.testing.expectEqual(@as(u32, 2), first.client_tick);
    try std.testing.expectEqual(@as(i8, 100), first.move_x);
    try std.testing.expectEqual(@as(i8, 0), first.move_y);
    try std.testing.expectEqual(@as(u16, 0), first.aim_angle);
    try std.testing.expectEqual(@as(u8, 0), first.buttons);
    conn.incoming.deinit(gpa);
    conn.read_accum.deinit(gpa);
}

test "frame parser waits for a partial frame" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var server = Server.init(std.Io.failing, gpa, &arena);

    var payload = wire.Sink.init();
    defer payload.deinit(gpa);
    try payload.leU32(gpa, 7); // input_seq
    try payload.leU32(gpa, 0); // client_tick
    try payload.byte(gpa, @as(u8, @bitCast(@as(i8, 100)))); // move_x
    try payload.byte(gpa, 0); // move_y
    try payload.leU16(gpa, 0); // aim_angle
    try payload.byte(gpa, 0); // buttons

    var wire_bytes = std.ArrayList(u8).empty;
    defer wire_bytes.deinit(gpa);
    try wire.writeFrame(gpa, &wire_bytes, wire.msg.c2s_input, payload.bytes(), 0);

    // Deliver the frame one byte short of complete.
    var conn = ClientConn{};
    const all = wire_bytes.items;
    try std.testing.expect(accumulateAndParse(&server, &conn, all[0 .. all.len - 1]));
    try std.testing.expectEqual(@as(usize, 0), conn.incoming.items.len);

    // The remaining byte completes it.
    try std.testing.expect(accumulateAndParse(&server, &conn, all[all.len - 1 ..]));
    try std.testing.expectEqual(@as(usize, 1), conn.incoming.items.len);
    try std.testing.expectEqual(@as(u32, 7), conn.incoming.items[0].input.input_seq);
    conn.incoming.deinit(gpa);
    conn.read_accum.deinit(gpa);
}

test "frame parser rejects oversized payloads" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var server = Server.init(std.Io.failing, gpa, &arena);

    // Craft a header announcing more payload than the parser accepts.
    var wire_bytes = std.ArrayList(u8).empty;
    defer wire_bytes.deinit(gpa);
    try wire_bytes.appendSlice(gpa, &.{ 0x02, 0xff, 0xff, 0, 0, 0, 0 });

    var conn = ClientConn{};
    try std.testing.expect(!accumulateAndParse(&server, &conn, wire_bytes.items));
    conn.read_accum.deinit(gpa);
}

test "a handshake queues a welcome and an immediate full snapshot" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var server = Server.init(std.Io.failing, gpa, &arena);
    try server.clients.append(gpa, .{});
    const conn = &server.clients.items[0];

    var payload = wire.Sink.init();
    defer payload.deinit(gpa);
    try payload.byte(gpa, 1); // proto_ver
    try payload.byte(gpa, 0); // requested_slot
    try payload.leU64(gpa, 0xdeadbeef); // session_token
    try payload.fixedBytes(gpa, &nameField("tester"));

    routeClient(&server, conn, wire.msg.c2s_hello, payload.bytes());

    try std.testing.expectEqual(@as(u8, 0), conn.player_id);
    try std.testing.expectEqual(@as(u64, 0xdeadbeef), conn.session_token);
    try std.testing.expectEqual(@as(usize, 2), conn.outgoing.items.len);

    const welcome = wire.decodeFrameHeader(conn.outgoing.items[0]).?;
    try std.testing.expectEqual(wire.msg.s2c_welcome, welcome.msg_type);
    const snapshot = wire.decodeFrameHeader(conn.outgoing.items[1]).?;
    try std.testing.expectEqual(wire.msg.s2c_snapshot_full, snapshot.msg_type);

    for (conn.outgoing.items) |frame| gpa.free(frame);
    conn.outgoing.deinit(gpa);
    conn.outgoing = std.ArrayList([]const u8).empty;
    for (server.clients.items) |*c| c.deinit(gpa);
    server.clients.deinit(gpa);
}

test "a HELLO with the wrong protocol version is refused" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var server = Server.init(std.Io.failing, gpa, &arena);
    try server.clients.append(gpa, .{});
    const conn = &server.clients.items[0];

    var payload = wire.Sink.init();
    defer payload.deinit(gpa);
    try payload.byte(gpa, 2);
    try payload.byte(gpa, 0);
    try payload.leU64(gpa, 1);
    try payload.fixedBytes(gpa, &nameField(""));

    routeClient(&server, conn, wire.msg.c2s_hello, payload.bytes());

    try std.testing.expect(conn.closed);
    try std.testing.expectEqual(@as(usize, 0), conn.outgoing.items.len);
    conn.outgoing.deinit(gpa);
    conn.outgoing = std.ArrayList([]const u8).empty;
    for (server.clients.items) |*c| c.deinit(gpa);
    server.clients.deinit(gpa);
}

test "a loopback connection completes HELLO, INPUT and SNAPSHOT_FULL" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var server = Server.init(io, gpa, &arena);
    try server.listen(0);
    defer server.shutdown();
    const port = server.listener.socket.address.getPort();

    const client = try net.IpAddress.connect(
        &.{ .ip4 = net.Ip4Address.loopback(port) },
        io,
        .{ .mode = .stream, .protocol = .tcp },
    );
    // Registered after `server.shutdown`, so it runs first: closing our end
    // makes the connection thread's `recv` return and lets shutdown join it.
    defer net.Stream.close(&client, io);

    var cwbuf: [0]u8 = .{};
    var cw = net.Stream.writer(client, io, &cwbuf);
    var crbuf: [512]u8 = undefined;
    var cr = net.Stream.reader(client, io, &crbuf);
    var slice: [1][]u8 = undefined;

    // C2S_HELLO. The connection thread is what reads the socket; wait until it
    // has handed the message over before stepping, so every step below produces
    // a known, bounded amount of traffic.
    var hello = wire.Sink.init();
    defer hello.deinit(gpa);
    try hello.byte(gpa, 1);
    try hello.byte(gpa, 0);
    try hello.leU64(gpa, 0x1234);
    try hello.fixedBytes(gpa, &nameField("tester"));
    const hello_frame = try wire.encodeFrame(gpa, wire.msg.c2s_hello, hello.bytes(), 0);
    defer gpa.free(hello_frame);
    try cw.interface.writeAll(hello_frame);
    try std.Io.Writer.flush(&cw.interface);

    // `C2S_HELLO` is dispatched by the connection thread itself, so the player
    // exists before any step; the step is what pushes the queued welcome out.
    try waitForPlayer(&server);

    server.step();
    try std.testing.expect(server.sim.players[0].active);
    try expectFrame(&cr, &slice, gpa, wire.msg.s2c_welcome);

    // C2S_INPUT.
    var input = wire.Sink.init();
    defer input.deinit(gpa);
    try input.leU32(gpa, 1);
    try input.leU32(gpa, 1);
    try input.byte(gpa, @as(u8, @bitCast(@as(i8, 100))));
    try input.byte(gpa, 0);
    try input.leU16(gpa, 0);
    try input.byte(gpa, 0);
    const input_frame = try wire.encodeFrame(gpa, wire.msg.c2s_input, input.bytes(), 1);
    defer gpa.free(input_frame);
    try cw.interface.writeAll(input_frame);
    try std.Io.Writer.flush(&cw.interface);

    try waitForQueuedMessage(&server);

    // The first step applies the input and integrates it; three steps always
    // contain exactly one broadcast, and that broadcast is encoded after the
    // position has moved.
    server.step();
    try std.testing.expectEqual(@as(u8, 0), server.sim.players[0].id);
    try std.testing.expectEqual(@as(u32, 1), server.sim.players[0].last_input_seq);
    try std.testing.expectEqual(
        @as(u8, @bitCast(server.sim.players[0].input.move_x)),
        100,
    );
    try std.testing.expect(server.sim.players[0].pos[0] > 0);
    server.step();
    server.step();

    // At most four frames can have been written by now — a snapshot left over
    // from the handshake step, plus at most one per step since — and the
    // snapshot carrying the moved position is among them, so none of these
    // reads can block.
    var seen_movement = false;
    var got: [512]u8 = undefined;
    for (0..4) |_| {
        const frame = try readFrame(&cr, &slice, &got);
        if (snapshotShowsMovement(frame)) {
            seen_movement = true;
            break;
        }
    }
    try std.testing.expect(seen_movement);
}

/// Spin until the connection thread has spawned the player, yielding so that
/// thread gets a chance to run. Fails the test rather than spinning forever.
fn waitForPlayer(server: *Server) !void {
    var spins: usize = 0;
    while (spins < 500_000) : (spins += 1) {
        server.lock();
        const spawned = server.sim.players[0].active;
        server.unlock();
        if (spawned) return;
        std.Thread.yield() catch {};
    }
    return error.PlayerNeverJoined;
}

/// Spin until the connection thread has queued a message for `step` to apply.
/// `C2S_INPUT` takes this path; `C2S_HELLO` does not.
fn waitForQueuedMessage(server: *Server) !void {
    var spins: usize = 0;
    while (spins < 500_000) : (spins += 1) {
        server.lock();
        const queued = server.clients.items.len > 0 and
            server.clients.items[0].incoming.items.len > 0;
        server.unlock();
        if (queued) return;
        std.Thread.yield() catch {};
    }
    return error.MessageNeverArrived;
}

/// True when `frame` is a full snapshot whose first player has moved in +x.
fn snapshotShowsMovement(frame: []const u8) bool {
    const header = wire.decodeFrameHeader(frame) orelse return false;
    if (header.msg_type != wire.msg.s2c_snapshot_full) return false;
    const payload = frame[wire.header_size..];
    if (payload.len < wire.snapshot_header_wire_size + wire.wireSize(wire.PlayerNet)) return false;
    const record = payload[wire.snapshot_header_wire_size..];
    return std.mem.bytesToValue(i16, record[2..4]) > 0;
}

/// Read one complete frame off `reader` into `buf` and return it.
///
/// Every read is bounded to the bytes still needed: `readVec` will happily
/// return more than asked for, and a read that runs past the frame boundary
/// would consume the next frame's bytes and lose them.
fn readFrame(reader: *net.Stream.Reader, slice: *[1][]u8, buf: []u8) ![]u8 {
    var filled: usize = 0;
    while (filled < wire.header_size) {
        slice[0] = buf[filled..wire.header_size];
        const n = reader.interface.readVec(slice) catch |e| {
            std.debug.print("[test] read failed: {s} | ", .{@errorName(e)});
            return e;
        };
        if (n == 0) return error.EndOfStream;
        filled += n;
    }
    const header = wire.decodeFrameHeader(buf[0..wire.header_size]).?;
    const total = wire.header_size + header.payload_len;
    while (filled < total) {
        slice[0] = buf[filled..total];
        const n = reader.interface.readVec(slice) catch return error.EndOfStream;
        if (n == 0) return error.EndOfStream;
        filled += n;
    }
    return buf[0..total];
}

/// Read one complete frame off `reader`, failing the test if the peer closes.
fn expectFrame(
    reader: *net.Stream.Reader,
    slice: *[1][]u8,
    gpa: std.mem.Allocator,
    want_msg: u8,
) !void {
    var got: [512]u8 = undefined;
    const frame = try readFrame(reader, slice, &got);
    const header = wire.decodeFrameHeader(frame).?;
    try std.testing.expectEqual(want_msg, header.msg_type);
    _ = gpa;
}
