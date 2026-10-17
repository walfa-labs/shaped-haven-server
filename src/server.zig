//! Shaped Haven server — transport and the 60 Hz simulation loop.
//!
//! Threading model. The simulation is single threaded and deterministic, and it
//! never performs blocking I/O. Four kinds of threads cooperate through one
//! mutex:
//!
//! * **simulation thread** (`run`) — drains per-client input queues, advances
//!   the simulation one fixed step, and enqueues outgoing snapshot frames.
//!   `step` never waits on a socket: it takes the queue lock, and the only
//!   socket call it can reach is `CloseHandle` on a connection it has already
//!   declared dead.
//! * **accept thread** — blocks in `net.Server.accept`, so a slow or absent
//!   client can never stall the tick loop. This is what keeps the listener
//!   non-blocking with respect to the simulation.
//! * **reader thread** (one per connection) — blocks in `recv` and parses
//!   frames into the connection's input queue.
//! * **writer thread** (one per connection) — blocks in `send` and drains the
//!   connection's output queue.
//!
//! Why the write side has its own thread. Writes used to happen on the
//! simulation thread, so a peer that stopped reading could fill the TCP window
//! and stall the 60 Hz tick inside `writeAll`. Moving them to the connection
//! would normally mean waking a thread parked in `recv`; that is not available
//! here, because this Zig build's `std.Io.Threaded` returns
//! `error.ConcurrencyUnavailable` for batched network operations on Windows.
//! There is no `select`, no timed socket I/O and no non-blocking send, so one
//! thread cannot wait on a socket and on a wakeup channel at the same time. A
//! dedicated writer thread per connection, woken by a semaphore, is the wakeup
//! mechanism that keeps the simulation thread off the socket entirely.
//!
//! Only the queues are shared. Each socket is owned by exactly one pair of
//! connection threads, so the lock is only ever held for queue bookkeeping,
//! never across a socket call.
//!
//! Connection lifetime. A `ClientConn` lives on the heap, so its address is
//! stable for as long as any thread holds a pointer to it. Membership in
//! `clients` is dropped only after both of its threads have been joined, so no
//! thread is ever left holding a pointer into storage that has been freed or
//! shifted.

const std = @import("std");
const root = @import("root.zig");
const wire = @import("wire.zig");
const sim = @import("sim.zig");
const delta = @import("delta.zig");
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

/// Bounds on a connection's outgoing queue. The writer thread drains it, so
/// these are only reached by a peer that has stopped reading; the queue stays
/// bounded so such a peer cannot make the server allocate without limit.
///
/// Overflow policy: the connection is dropped. Phase 1 sends full snapshots
/// only, so skipping frames would leave the client with a state stream it
/// cannot interpret, and the client has no way to ask for a resend yet.
const max_queued_frames: usize = 16;
const max_queued_bytes: usize = 256 * 1024;

/// A connection slot that has not completed `C2S_HELLO` yet.
pub const unassigned_player: u8 = 0xff;

/// A decoded client message, queued for the simulation thread.
///
/// `C2S_ACK_SNAPSHOT` is deliberately not here: an acknowledgement is pure
/// connection state, never simulation state, and the broadcast has to be able
/// to see the newest one at the instant it encodes. See
/// `ClientConn.last_recv_server_tick`.
pub const Incoming = union(enum) {
    hello: wire.Hello,
    input: wire.Input,
    levelup_choice: wire.LevelupChoice,
    restart: void,
};

/// One encoded frame waiting to go out, reference counted.
///
/// A broadcast hands the *same* bytes to every eligible connection, so a frame
/// has no single owner: the reference count is what lets the first consumer to
/// finish free it without pulling the bytes out from under the others, and what
/// frees a frame that nobody was eligible to receive.
const Frame = struct {
    refs: std.atomic.Value(u32),
    bytes: []u8,

    /// Takes ownership of `bytes` and returns a frame with one reference held.
    fn create(gpa: std.mem.Allocator, bytes: []u8) !*Frame {
        const frame = try gpa.create(Frame);
        frame.* = .{ .refs = .init(1), .bytes = bytes };
        return frame;
    }

    fn retain(frame: *Frame) void {
        _ = frame.refs.fetchAdd(1, .monotonic);
    }

    fn release(frame: *Frame, gpa: std.mem.Allocator) void {
        if (frame.refs.fetchSub(1, .acq_rel) == 1) {
            gpa.free(frame.bytes);
            gpa.destroy(frame);
        }
    }
};

/// Wrap `bytes` in a frame, freeing them if the frame cannot be allocated so
/// a failed encode never leaks its payload.
fn frameOrFree(gpa: std.mem.Allocator, bytes: []u8) !*Frame {
    return Frame.create(gpa, bytes) catch |e| {
        gpa.free(bytes);
        return e;
    };
}

/// One accepted TCP connection and its parse/write state.
///
/// Always heap allocated: the connection threads hold a raw pointer to it, and
/// `clients` holds that same pointer rather than a copy, so a slot never moves.
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
    outgoing: std.ArrayList(*Frame) = .empty,
    /// Sum of `outgoing` frame lengths, so the queue bound is an O(1) check.
    queued_bytes: usize = 0,
    /// Offset of the first unparsed byte inside `read_accum`.
    accum_offset: usize = 0,
    name: [16]u8 = std.mem.zeroes([16]u8),
    session_token: u64 = 0,
    /// Newest `server_tick` this client has acknowledged, and the tick it is
    /// expected to hold a complete state for.
    ///
    /// Both are written by the reader thread the instant an ack is decoded, not
    /// queued for the simulation thread: an acknowledgement is pure connection
    /// state, and the encoder has to see the freshest one the server has
    /// processed *at the moment it encodes*.
    ///
    /// The acknowledgement alone cannot name the baseline. The client only
    /// flushes an ack when the next snapshot lands, so the ack for tick N
    /// reaches the server a few hundred microseconds *after* the broadcast for
    /// N+3 has been built; a delta diffed against it names a tick the client
    /// left a whole snapshot ago, and the client refuses it under PROTOCOL.md
    /// "Baseline rules". Measured against the real client over a live run, 48%
    /// of every delta was refused that way. So the server carries the tick
    /// forward itself: a client holds exactly one complete state and moves it to
    /// any snapshot it applies, so `held_tick` advances to each snapshot's own
    /// tick as that snapshot is sent, and the acknowledgement is what corrects
    /// the model whenever the two ever disagree.
    acked_tick: std.atomic.Value(u32) = .init(0),
    held_tick: std.atomic.Value(u32) = .init(0),
    /// The tick the model held before the snapshot it most recently sent
    /// advanced it — the baseline that snapshot was diffed against, or, for a
    /// full snapshot, the tick the client held before it arrived.
    ///
    /// It is the second of the two ticks `noteAck` lets the model account for
    /// without assuming the client is stuck: a client that has not processed
    /// that snapshot yet, or that refused it, still holds this one. Written by
    /// the simulation thread as it builds a frame, read by the reader thread as
    /// it decodes an ack.
    held_baseline: std.atomic.Value(u32) = .init(0),
    /// Where this connection's per-snapshot update budget starts inside the
    /// candidate set. Advanced by the number of records each snapshot actually
    /// carried, so the entities one snapshot could not afford lead the next.
    /// The simulation thread is its only writer.
    update_rotation: u32 = 0,
    /// The state this client holds: its own interest-filtered neighbourhood,
    /// entity for entity. Built from a full snapshot, rebuilt from the history
    /// ring when the model is corrected, and thereafter changed only by the
    /// records that actually went out — never by the ones the per-snapshot
    /// budget deferred, which is what makes the next diff offer them again.
    ///
    /// A few hundred kilobytes, because it is sized for the whole world and
    /// holds only a neighbourhood. The simulation thread is its only writer.
    held: delta.FilteredWorld = .{},
    /// The tick `held` describes. Diverging from `held_tick` means the model was
    /// corrected since the state was built, so the state has to be rebuilt from
    /// the ring before the next diff. The simulation thread is its only writer.
    held_tick_content: u32 = 0,

    /// Set when the connection must stop: the peer closed, a read or write
    /// failed, or the server decided the connection is unusable. Written by
    /// whichever thread notices first, read by all of them.
    closed: std.atomic.Value(bool) = .init(false),
    /// Guards `net.Stream.close`, so the socket handle is closed exactly once.
    stream_closed: std.atomic.Value(bool) = .init(false),
    /// Number of connection threads that have returned. `reap` only joins a
    /// connection once this reaches two, so joining never blocks the tick.
    threads_exited: std.atomic.Value(u8) = .init(0),

    /// Guarded by the server lock: `reap` has already closed the socket.
    killed: bool = false,
    /// Guarded by the server lock: `reap` is joining this connection, so it is
    /// only ever handed to the reaper once.
    retiring: bool = false,

    /// Wakes the writer thread when a frame is queued or the connection dies.
    write_sem: std.Io.Semaphore = .{},
    reader: ?std.Thread = null,
    writer: ?std.Thread = null,

    pub fn deinit(c: *ClientConn, gpa: std.mem.Allocator) void {
        c.read_accum.deinit(gpa);
        c.incoming.deinit(gpa);
        for (c.outgoing.items) |frame| frame.release(gpa);
        c.outgoing.deinit(gpa);
        gpa.free(c.read_buf);
        gpa.free(c.write_buf);
    }

    /// Record an acknowledgement of `tick`, correcting the held-state model.
    ///
    /// Caller holds the lock. Called from the reader thread as the ack is
    /// decoded, so the correction is in place before the next frame is encoded.
    ///
    /// The rule, in full: an ack corrects the model when it names a tick the
    /// model cannot account for, and it does so on the first such ack.
    ///
    /// What the model can account for, once it has sent a snapshot, is exactly
    /// two ticks — the tick that snapshot carried, which the client holds if it
    /// applied it, and the tick it was diffed against, which the client still
    /// holds if it has not processed it yet. An ack naming either is a client
    /// that is keeping up, or lagging by the one snapshot the model has just
    /// carried it past, and it changes nothing: the model's advance onto each
    /// snapshot is what keeps the baseline where the client's next apply needs
    /// it, and pulling it back for every ack that trails would put it a whole
    /// snapshot behind and make the client refuse the next delta — the 48%
    /// refusal the carry-forward model exists to remove.
    ///
    /// Any other tick is a client holding a state the model cannot explain: it
    /// has run further ahead than one unprocessed snapshot accounts for, so the
    /// model is wrong and the ack is the truth. Correcting there and then is
    /// the point of the rule. The predicate this replaced waited for the client
    /// to repeat itself before it would believe an ack, which meant the first
    /// corrective ack of a drifted model — the one that is different from the
    /// previous ack — was ignored, and the model went on diffing against a tick
    /// the client had already refused for another whole round trip.
    ///
    /// A repeat is still a correction in its own right, whether or not it names
    /// the last baseline: a client that applied the snapshot it is answering
    /// holds a newer tick and cannot ack the same one twice, so a repeat is the
    /// client insisting on the state it really holds.
    ///
    /// The tolerance is exactly one snapshot, because one send is all the model
    /// advances at a time and so the only older tick a single unprocessed
    /// snapshot explains. A client whose acks trail by more than that — which
    /// takes a round trip plus a client frame longer than the 50 ms between
    /// snapshots — is read as disagreeing, and correcting to an ack two
    /// snapshots stale costs a refused delta before the client's own re-ack
    /// settles the model on the tick it really holds. Measured against the real
    /// client over a 6,000-frame run, the acks trail by no more than that one
    /// snapshot: 828 deltas applied, one refused, and that one inside the
    /// seeding transient.
    pub fn noteAck(c: *ClientConn, tick: u32) void {
        const previous = c.acked_tick.swap(tick, .acq_rel);
        const held = c.held_tick.load(.acquire);
        const baseline = c.held_baseline.load(.acquire);
        if (tick > held or (tick != held and tick != baseline) or
            (tick == previous and tick != held))
        {
            c.held_tick.store(tick, .release);
        }
    }

    /// Drop the held-state model: the run it described has ended.
    ///
    /// Caller holds the lock.
    pub fn forgetRun(c: *ClientConn) void {
        c.acked_tick.store(0, .release);
        c.held_tick.store(0, .release);
        c.held_baseline.store(0, .release);
    }
};

pub const Server = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// Backs the `clients` list itself. The connections it points at are
    /// allocated with `gpa` so that they can be released individually.
    arena: *std.heap.ArenaAllocator,
    sim: sim.Simulation,
    /// The 32-snapshot history ring a delta baseline is diffed against. Heap
    /// allocated: at 32 full-world snapshots it is a few megabytes, far too
    /// large to keep inline in a `Server` that tests put on the stack.
    snapshots: *delta.SnapshotRing,
    /// Reusable scratch for the per-client snapshot diff, also heap allocated.
    diff_scratch: *delta.DiffScratch,
    mu: std.Io.Mutex = .init,
    /// Pointers, not values: a connection's address has to stay put for the
    /// whole life of its threads, so removing one can never move another.
    clients: std.ArrayList(*ClientConn) = .empty,
    accept_thread: ?std.Thread = null,
    listener: net.Server = undefined,
    stopping: std.atomic.Value(bool) = .init(false),

    pub fn init(
        io: std.Io,
        gpa: std.mem.Allocator,
        arena: *std.heap.ArenaAllocator,
    ) Server {
        // The history ring and the diff scratch are allocated from the arena,
        // which outlives the server and is deinited by the caller.
        const snapshots = arena.allocator().create(delta.SnapshotRing) catch @panic("out of memory");
        snapshots.* = .{};
        // The ring starts empty: every slot tick 0, which is not a valid
        // snapshot tick, so a baseline lookup finds nothing until a snapshot
        // has actually been stored.
        @memset(
            @as([*]u8, @ptrCast(&snapshots.slots))[0..@sizeOf(@TypeOf(snapshots.slots))],
            0,
        );
        const diff_scratch = arena.allocator().create(delta.DiffScratch) catch @panic("out of memory");
        diff_scratch.* = .{};

        return .{
            .io = io,
            .gpa = gpa,
            .arena = arena,
            .sim = sim.Simulation.init(),
            .snapshots = snapshots,
            .diff_scratch = diff_scratch,
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
        self.stopping.store(true, .release);

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

        // The accept thread is joined and the listener is closed, so nothing
        // can add to `clients` from here on. Close every socket first — that is
        // what unblocks a thread parked in `recv` or in a `send` the peer's
        // window has stalled — and only then join, so one dead peer cannot hold
        // up the rest.
        self.lock();
        for (self.clients.items) |conn| markClosed(self, conn);
        self.unlock();
        for (self.clients.items) |conn| closeStream(self, conn);
        for (self.clients.items) |conn| {
            if (conn.reader) |thread| thread.join();
            if (conn.writer) |thread| thread.join();
            conn.deinit(self.gpa);
            self.gpa.destroy(conn);
        }

        self.lock();
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

        while (!self.stopping.load(.acquire)) {
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
                const deadline = nextTickDeadline(
                    std.Io.Clock.Timestamp.now(self.io, .awake),
                    accumulator,
                    tick_ns,
                );
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
    ///
    /// Never waits on a socket. The only socket call reachable from here is
    /// `CloseHandle` in `reap`, on a connection that is already dead; that does
    /// not wait for the peer, so a stalled client cannot stretch a tick.
    pub fn step(self: *Server) void {
        // 1. Drain parsed input and apply it, all under the lock. The lock also
        //    guards the outgoing queues, which `handleHello` appends to, so it
        //    has to be held across dispatch.
        //
        //    Nothing is removed from `incoming` until it has been dispatched,
        //    so a message can never be lost between the two lists.
        self.lock();
        for (self.clients.items) |conn| {
            while (conn.incoming.items.len > 0) {
                const message = conn.incoming.orderedRemove(0);
                dispatch(self, conn, message);
            }
        }
        self.unlock();

        // 2. Integrate.
        self.sim.advance();

        // 3. Drain the progression events the step produced: level-up offers,
        //    loadout changes and game over. All under the lock, because the
        //    outgoing queues are guarded by it.
        self.sendProgressionEvents();

        // 4. Broadcast a full snapshot at 20 Hz.
        if (self.sim.tick % root.ticks_per_snapshot == 0) {
            self.broadcast();
        }

        // 5. Retire connections whose threads have finished.
        self.reap();
    }

    /// Send the level-up offers, loadout updates and the game-over frame the
    /// simulation produced since the last step.
    ///
    /// The caller must not hold the lock; this takes it.
    fn sendProgressionEvents(self: *Server) void {
        self.lock();
        defer self.unlock();

        for (self.sim.pending_levelups[0..self.sim.pending_count]) |*ev| {
            if (ev.sent) continue;
            const conn = self.connForPlayer(ev.player_id) orelse continue;
            if (levelupOfferFrame(self.gpa, ev)) |frame| {
                self.enqueueBytes(conn, frame);
                ev.sent = true;
            } else |e| {
                std.debug.print("[server] level-up offer encode failed: {s}\n", .{@errorName(e)});
            }
        }

        for (self.sim.players, 0..) |p, i| {
            if (!self.sim.loadout_dirty[i]) continue;
            const conn = self.connForPlayer(p.id) orelse continue;
            if (loadoutFrame(self.gpa, &self.sim, p.id)) |frame| {
                self.enqueueBytes(conn, frame);
                self.sim.loadout_dirty[i] = false;
            } else |e| {
                std.debug.print("[server] loadout encode failed: {s}\n", .{@errorName(e)});
            }
        }

        if (self.sim.game_over_pending) {
            if (gameOverFrame(self.gpa, &self.sim)) |frame| {
                if (Frame.create(self.gpa, frame)) |shared| {
                    for (self.clients.items) |conn| {
                        if (conn.player_id == unassigned_player) continue;
                        shared.retain();
                        self.enqueue(conn, shared);
                    }
                    shared.release(self.gpa);
                } else |e| {
                    self.gpa.free(frame);
                    std.debug.print("[server] game over frame alloc failed: {s}\n", .{@errorName(e)});
                }
            } else |e| {
                std.debug.print("[server] game over encode failed: {s}\n", .{@errorName(e)});
            }
            self.sim.game_over_pending = false;
        }
    }

    /// The connection serving `player_id`, or `null`. Caller holds the lock.
    fn connForPlayer(self: *Server, player_id: u8) ?*ClientConn {
        for (self.clients.items) |conn| {
            if (conn.player_id == player_id) return conn;
        }
        return null;
    }

    /// Wrap `bytes` in a frame and queue it. Caller holds the lock.
    fn enqueueBytes(self: *Server, conn: *ClientConn, bytes: []u8) void {
        if (Frame.create(self.gpa, bytes)) |frame| {
            self.enqueue(conn, frame);
        } else |_| {
            self.gpa.free(bytes);
            markClosed(self, conn);
        }
    }

    /// Encode one snapshot per connection that wants it and queue them.
    ///
    /// Each connection gets its own frame, because a delta is diffed against
    /// that connection's acknowledged baseline and filtered to its own
    /// neighbourhood — two clients rarely want the same bytes any more.
    fn broadcast(self: *Server) void {
        // Encoding for nobody is worth avoiding: a snapshot carrying a thousand
        // enemies is around 18 KB, and a client that has dropped mid-run would
        // otherwise leave the server allocating and freeing one every 50 ms.
        self.lock();
        var wanted = false;
        for (self.clients.items) |conn| {
            if (receivesSnapshots(conn)) {
                wanted = true;
                break;
            }
        }
        self.unlock();
        if (!wanted) return;

        // Record the whole world at this tick in the history ring. The slot is
        // a stable copy, so it is what a later acknowledgement correction is
        // rebuilt from, and the interest-filtered snapshots below — which reuse
        // the sim's scratch — cannot disturb it.
        const view = self.sim.snapshotView();
        self.snapshots.store(view);

        var frames: [root.max_players]struct { conn: *ClientConn, frame: *Frame } = undefined;
        var n_frames: usize = 0;
        for (self.clients.items) |conn| {
            if (!receivesSnapshots(conn)) continue;
            if (self.snapshotFrame(conn)) |frame| {
                frames[n_frames] = .{ .conn = conn, .frame = frame };
                n_frames += 1;
            } else |e| {
                std.debug.print("[server] error: could not encode snapshot: {s}\n", .{@errorName(e)});
            }
        }

        self.lock();
        defer self.unlock();
        for (frames[0..n_frames]) |f| {
            self.enqueue(f.conn, f.frame);
        }
    }

    /// Encode the one snapshot this connection wants: a delta against the model
    /// of what its client holds, or a full snapshot of its neighbourhood when
    /// there is no usable model.
    fn snapshotFrame(self: *Server, conn: *ClientConn) !*Frame {
        const centre = self.sim.players[conn.player_id].pos;
        const tick = self.sim.tick;
        const held = &conn.held;

        // Read at the moment of encoding, not at the top of the tick: an ack
        // that landed while the tick was being simulated is exactly the one
        // this frame should be diffed against.
        var model = conn.held_tick.load(.acquire);
        if (model > tick) {
            // A restart took the server's tick back to zero, so a tick held
            // from the dead run names nothing this client has any more.
            model = 0;
            conn.held_tick.store(0, .release);
        }
        // Record what the model holds going into this frame, before the frame
        // advances it. It is the baseline a delta is diffed against, and it is
        // what `noteAck` reads to tell an ack that is merely lagging behind this
        // snapshot from one naming a state the model cannot account for.
        conn.held_baseline.store(model, .release);

        // Bring the held state in line with the model — a no-op while the two
        // already agree. When they do not, there is no usable model at all and
        // the client gets a full snapshot: the only honest answer, and one it
        // keeps getting until an acknowledgement proves it is holding it.
        if (!self.syncHeld(conn, model)) {
            conn.held_tick.store(0, .release);
            return self.fullSnapshotFrame(conn, centre, tick);
        }

        const current = self.sim.snapshotViewFor(centre, root.interest_radius);
        const d = delta.computeDelta(current, held, .{
            .rotation = conn.update_rotation,
        }, self.diff_scratch);
        const bytes = wire.encodeSnapshotDelta(self.gpa, .{
            .server_tick = tick,
            .baseline_tick = model,
            .run_time_ms = self.sim.runTimeMs(),
            .acked_seq = self.sim.ackedSeq(),
            .game_state = @intFromEnum(self.sim.state),
            .spawned = d.spawned,
            .updated = d.updated,
            .destroyed = d.destroyed,
        }) catch |e| return e;

        // The model moves onto the records that actually went out, and only
        // those: the budget's deferred updates stay un-applied, so the next diff
        // still finds them changed and offers them again.
        held.apply(d);
        conn.held_tick_content = tick;
        conn.held_tick.store(tick, .release);
        // Start the next snapshot where this one stopped, so the entities the
        // budget deferred lead the next window instead of trailing it forever.
        conn.update_rotation +%= @intCast(d.updated.len);
        return frameOrFree(self.gpa, bytes);
    }

    /// Bring `conn`'s held state in line with the model tick `model`.
    ///
    /// The model is corrected by an acknowledgement that disagrees with it
    /// (PROTOCOL.md "Baseline rules"), so the state it used to describe is no
    /// longer the state the client holds. When the two disagree, the state is
    /// rebuilt from the ring's snapshot of that tick, filtered around the
    /// position the receiver's player held *then* — which is the neighbourhood
    /// the client's own state was filtered around.
    ///
    /// Returns false when there is no usable model: tick 0, a tick the ring no
    /// longer holds, or one whose snapshot did not carry the player. The caller
    /// answers that with a full snapshot.
    fn syncHeld(self: *Server, conn: *ClientConn, model: u32) bool {
        if (model != 0 and model == conn.held_tick_content and
            self.snapshots.baseline(model) != null)
        {
            return true;
        }
        const slot = self.snapshots.baseline(model) orelse return false;
        const centre = delta.playerPosInSlot(slot, conn.player_id) orelse return false;
        conn.held.setFromSlot(slot, centre, root.interest_radius);
        conn.held_tick_content = model;
        // The candidate set changed wholesale, so the rotation starts over.
        conn.update_rotation = 0;
        return true;
    }

    /// A full snapshot of `conn`'s neighbourhood, which replaces whatever the
    /// client held outright.
    ///
    /// The model tick is deliberately left alone: a client that has not
    /// acknowledged anything keeps getting full snapshots until it proves it is
    /// holding one. The state the full snapshot describes *is* recorded, so an
    /// acknowledgement of this very snapshot finds the model already in place.
    fn fullSnapshotFrame(self: *Server, conn: *ClientConn, centre: [2]f32, tick: u32) !*Frame {
        const full = self.sim.snapshotViewFor(centre, root.interest_radius);
        const bytes = wire.encodeSnapshotFull(self.gpa, full) catch |e| return e;
        conn.held.setFromView(full);
        conn.held_tick_content = tick;
        conn.update_rotation = 0;
        return frameOrFree(self.gpa, bytes);
    }

    /// Queue a frame on one connection, taking ownership of its reference.
    ///
    /// The caller must hold the lock.
    fn enqueue(self: *Server, conn: *ClientConn, frame: *Frame) void {
        if (conn.outgoing.items.len >= max_queued_frames or
            conn.queued_bytes + frame.bytes.len > max_queued_bytes)
        {
            std.debug.print(
                "[server] disconnect: player {d} is not draining its outgoing queue\n",
                .{conn.player_id},
            );
            frame.release(self.gpa);
            markClosed(self, conn);
            return;
        }

        conn.outgoing.append(self.gpa, frame) catch |e| {
            std.debug.print(
                "[server] disconnect: could not queue a frame for player {d}: {s}\n",
                .{ conn.player_id, @errorName(e) },
            );
            frame.release(self.gpa);
            markClosed(self, conn);
            return;
        };
        conn.queued_bytes += frame.bytes.len;
        conn.write_sem.post(self.io);
    }

    /// Close the socket of every dead connection, then join and release the
    /// connections whose threads have both returned.
    ///
    /// Closing the socket is what lets a thread parked in `recv` or in a `send`
    /// that the peer's window has stalled leave; `shutdown` does not do it (a
    /// pending `AFD_SEND` survives a partial disconnect), and the join would
    /// otherwise hang. Joining is skipped until both threads have recorded that
    /// they returned, so it cannot block the tick.
    fn reap(self: *Server) void {
        while (true) {
            self.lock();
            var victim: ?*ClientConn = null;
            for (self.clients.items) |conn| {
                if (conn.killed or !conn.closed.load(.acquire)) continue;
                conn.killed = true;
                victim = conn;
                break;
            }
            self.unlock();
            const conn = victim orelse break;
            closeStream(self, conn);
            conn.write_sem.post(self.io);
        }

        while (true) {
            self.lock();
            var victim: ?*ClientConn = null;
            for (self.clients.items) |conn| {
                if (conn.retiring) continue;
                if (conn.threads_exited.load(.acquire) < 2) continue;
                conn.retiring = true;
                victim = conn;
                break;
            }
            self.unlock();
            const conn = victim orelse break;

            if (conn.reader) |thread| thread.join();
            if (conn.writer) |thread| thread.join();

            self.lock();
            for (self.clients.items, 0..) |c, i| {
                if (c == conn) {
                    _ = self.clients.swapRemove(i);
                    break;
                }
            }
            if (conn.player_id != unassigned_player) self.sim.despawnPlayer(conn.player_id);
            self.unlock();

            std.debug.print("[server] player {d} disconnected\n", .{conn.player_id});
            conn.deinit(self.gpa);
            self.gpa.destroy(conn);
        }
    }

    /// Connected sockets, for diagnostics.
    pub fn clientCount(self: *Server) usize {
        self.lock();
        defer self.unlock();
        return self.clients.items.len;
    }
};

/// Wall-clock instant at which the next tick is due.
///
/// `accumulator` is the time already elapsed *towards* the next tick, so the
/// wait still owed is `tick_ns - accumulator`, measured from `now`. Measuring
/// that remainder from the start of the frame instead puts the deadline in the
/// past, which turns the wait into a busy loop and makes the tick rate depend
/// on how long a step happened to take.
fn nextTickDeadline(
    now: std.Io.Clock.Timestamp,
    accumulator: i96,
    tick_ns: i96,
) std.Io.Clock.Timestamp {
    const remaining = @max(tick_ns - accumulator, 0);
    return std.Io.Clock.Timestamp.addDuration(now, .{
        .raw = .{ .nanoseconds = remaining },
        .clock = .awake,
    });
}

/// True when this connection should be sent game state. A connection that has
/// not finished its handshake has no business receiving it: the snapshot would
/// reach the wire ahead of the welcome frame.
fn receivesSnapshots(conn: *const ClientConn) bool {
    return !conn.closed.load(.acquire) and conn.player_id != unassigned_player;
}

/// Mark a connection dead and wake its writer. Safe to call under the lock:
/// it only stores a flag and posts a semaphore.
fn markClosed(self: *Server, conn: *ClientConn) void {
    conn.closed.store(true, .release);
    conn.write_sem.post(self.io);
}

/// Close a connection's socket exactly once.
///
/// The caller must not hold the lock: this is a syscall. Any thread may call it
/// — closing the handle is what unblocks a peer-stalled `recv` or `send` — and
/// `stream_closed` makes sure the handle is released exactly once.
fn closeStream(self: *Server, conn: *ClientConn) void {
    if (conn.stream_closed.cmpxchgStrong(false, true, .acq_rel, .monotonic) != null) return;
    net.Stream.close(&conn.stream, self.io);
}

/// Apply one queued client message to the simulation.
fn dispatch(self: *Server, conn: *ClientConn, message: Incoming) void {
    switch (message) {
        .hello => |hello| handleHello(self, conn, hello),
        .input => |input| {
            if (conn.player_id != unassigned_player) self.sim.applyInput(conn.player_id, input);
        },
        .levelup_choice => |choice| {
            if (conn.player_id == unassigned_player) return;
            _ = self.sim.submitChoice(conn.player_id, choice.event_id, choice.choice_idx);
        },
        .restart => {
            if (conn.player_id == unassigned_player) return;
            self.sim.restart(conn.player_id);
            // The run's tick goes back to zero, so every connection's
            // held-state model names a tick of the dead run. Left alone, a model
            // whose tick happened to coincide with the new run's would diff
            // against it, and the client — which drops its own baseline with the
            // run — refuses a delta whose baseline it does not hold *without
            // acknowledging*, so the two could never re-converge.
            for (self.clients.items) |c| c.forgetRun();
        },
    }
}

fn handleHello(self: *Server, conn: *ClientConn, hello: wire.Hello) void {
    if (conn.player_id != unassigned_player) {
        std.debug.print("[server] note: duplicate HELLO on an assigned slot; ignored\n", .{});
        return;
    }
    if (hello.proto_ver != root.protocol_version) {
        std.debug.print(
            "[server] disconnect: proto_ver {d}, expected {d}\n",
            .{ hello.proto_ver, root.protocol_version },
        );
        markClosed(self, conn);
        return;
    }

    const player = self.sim.spawnPlayer(hello.requested_slot) orelse {
        std.debug.print("[server] disconnect: no free player slot\n", .{});
        markClosed(self, conn);
        return;
    };

    conn.session_token = hello.session_token;
    conn.player_id = player.id;
    @memcpy(&conn.name, &hello.name);
    std.debug.print("[server] player {d} joined as '{s}'\n", .{ player.id, conn.name });

    // The stress load is topped up at the end of a tick, so the snapshot below
    // would otherwise be taken before this player's first one — the client's
    // first view of the world would be short of the load it is there to
    // measure. Placing it here as well costs nothing: the tick tops it up
    // again immediately afterwards.
    if (self.sim.stress) |load| {
        self.sim.topUpLoad(load.enemies, load.projectiles, load.radius);
    }

    // The welcome and an immediate full snapshot, so the client need not wait
    // 50 ms for its first state. Both go to this connection's write queue and
    // its writer thread sends them as soon as it is woken.
    const welcome = welcomeFrame(self.gpa, conn, player.id, self.sim.tick) catch |e| {
        std.debug.print("[server] welcome encode failed: {s}\n", .{@errorName(e)});
        markClosed(self, conn);
        return;
    };
    self.enqueue(conn, Frame.create(self.gpa, welcome) catch {
        std.debug.print("[server] disconnect: out of memory queuing a welcome\n", .{});
        self.gpa.free(welcome);
        markClosed(self, conn);
        return;
    });

    // The client has no baseline yet, so this is a full snapshot of its
    // neighbourhood (PROTOCOL.md: a baseline of 0 gets a full snapshot). The
    // state it describes is recorded as the client's held state, so the
    // acknowledgement of this very snapshot needs no rebuild from the ring —
    // and this one is taken outside a broadcast, so the ring may never hold it.
    const first = self.sim.snapshotViewFor(player.pos, root.interest_radius);
    conn.held.setFromView(first);
    conn.held_tick_content = self.sim.tick;
    const snapshot = wire.encodeSnapshotFull(
        self.gpa,
        first,
    ) catch |e| {
        std.debug.print("[server] snapshot encode failed: {s}\n", .{@errorName(e)});
        markClosed(self, conn);
        return;
    };
    self.enqueue(conn, Frame.create(self.gpa, snapshot) catch {
        std.debug.print("[server] disconnect: out of memory queuing a snapshot\n", .{});
        self.gpa.free(snapshot);
        markClosed(self, conn);
        return;
    });

    // The loadout so the client's HUD is populated from the first frame.
    if (loadoutFrame(self.gpa, &self.sim, player.id)) |frame| {
        self.enqueueBytes(conn, frame);
    } else |e| {
        std.debug.print("[server] loadout encode failed: {s}\n", .{@errorName(e)});
        markClosed(self, conn);
        return;
    }
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
    try payload.leU16(gpa, @as(u16, @intFromFloat(root.interest_radius)));
    try payload.leU16(gpa, 0); // reserved
    try payload.leU32(gpa, server_tick);

    return wire.encodeFrame(gpa, wire.msg.s2c_welcome, payload.bytes(), 0);
}

/// `S2C_LEVELUP_OFFER` for one pending level-up.
fn levelupOfferFrame(gpa: std.mem.Allocator, ev: *sim.LevelUp) ![]u8 {
    var options: [3]wire.UpgradeOptionNet = undefined;
    for (ev.options, 0..) |opt, i| {
        options[i] = .{
            .item_id = opt.item_id,
            .next_level = opt.next_level,
            .is_evo = @intFromBool(opt.is_evo),
        };
    }
    return wire.encodeLevelupOffer(gpa, ev.player_id, ev.event_id, ev.new_level, &options);
}

/// `S2C_LOADOUT` for one player. Empty slots are padded with `0xff`.
fn loadoutFrame(gpa: std.mem.Allocator, s: *sim.Simulation, player_id: u8) ![]u8 {
    const p = &s.players[player_id];

    var l: wire.Loadout = .{
        .player_id = p.id,
        .level = p.level,
        .xp = p.xp,
        .xp_next = p.xp_next,
        .weapon_count = 0,
        .w0_item_id = 0xff, .w0_level = 0, .w0_evolved = 0,
        .w1_item_id = 0xff, .w1_level = 0, .w1_evolved = 0,
        .w2_item_id = 0xff, .w2_level = 0, .w2_evolved = 0,
        .w3_item_id = 0xff, .w3_level = 0, .w3_evolved = 0,
        .passive_count = 0,
        .p0_item_id = 0xff, .p0_level = 0,
        .p1_item_id = 0xff, .p1_level = 0,
        .p2_item_id = 0xff, .p2_level = 0,
        .p3_item_id = 0xff, .p3_level = 0,
        .p4_item_id = 0xff, .p4_level = 0,
        .p5_item_id = 0xff, .p5_level = 0,
        .p6_item_id = 0xff, .p6_level = 0,
        .p7_item_id = 0xff, .p7_level = 0,
        .p8_item_id = 0xff, .p8_level = 0,
        .p9_item_id = 0xff, .p9_level = 0,
    };

    for (p.weapons, 0..) |slot, i| {
        if (slot.isFree()) continue;
        switch (i) {
            0 => {
                l.w0_item_id = slot.id;
                l.w0_level = slot.level;
                l.w0_evolved = @intFromBool(slot.evolved);
            },
            1 => {
                l.w1_item_id = slot.id;
                l.w1_level = slot.level;
                l.w1_evolved = @intFromBool(slot.evolved);
            },
            2 => {
                l.w2_item_id = slot.id;
                l.w2_level = slot.level;
                l.w2_evolved = @intFromBool(slot.evolved);
            },
            3 => {
                l.w3_item_id = slot.id;
                l.w3_level = slot.level;
                l.w3_evolved = @intFromBool(slot.evolved);
            },
            else => {},
        }
        l.weapon_count += 1;
    }
    for (p.passives, 0..) |lvl, i| {
        if (lvl == 0) continue;
        switch (i) {
            0 => {
                l.p0_item_id = 16 + @as(u8, @intCast(i));
                l.p0_level = lvl;
            },
            1 => {
                l.p1_item_id = 16 + @as(u8, @intCast(i));
                l.p1_level = lvl;
            },
            2 => {
                l.p2_item_id = 16 + @as(u8, @intCast(i));
                l.p2_level = lvl;
            },
            3 => {
                l.p3_item_id = 16 + @as(u8, @intCast(i));
                l.p3_level = lvl;
            },
            4 => {
                l.p4_item_id = 16 + @as(u8, @intCast(i));
                l.p4_level = lvl;
            },
            5 => {
                l.p5_item_id = 16 + @as(u8, @intCast(i));
                l.p5_level = lvl;
            },
            6 => {
                l.p6_item_id = 16 + @as(u8, @intCast(i));
                l.p6_level = lvl;
            },
            7 => {
                l.p7_item_id = 16 + @as(u8, @intCast(i));
                l.p7_level = lvl;
            },
            8 => {
                l.p8_item_id = 16 + @as(u8, @intCast(i));
                l.p8_level = lvl;
            },
            9 => {
                l.p9_item_id = 16 + @as(u8, @intCast(i));
                l.p9_level = lvl;
            },
            else => {},
        }
        l.passive_count += 1;
    }

    return wire.encodeLoadout(gpa, l);
}

/// `S2C_GAME_OVER`. The score is the best connected player's, and the kill
/// count is the run's.
fn gameOverFrame(gpa: std.mem.Allocator, s: *sim.Simulation) ![]u8 {
    var best: u32 = 0;
    for (s.players) |p| {
        if (!p.active) continue;
        best = @max(best, s.scoreFor(p.id));
    }
    return wire.encodeGameOver(gpa, .{
        .final_tick = s.final_tick,
        .seconds_survived = s.final_tick / root.tick_hz,
        .score = best,
        .kills = s.kills,
    });
}

/// NUL-padded `[16]u8` client name for a `C2S_HELLO`.
fn nameField(name: []const u8) [16]u8 {
    var out = std.mem.zeroes([16]u8);
    @memcpy(out[0..@min(name.len, out.len)], name);
    return out;
}

fn acceptThread(self: *Server) void {
    while (!self.stopping.load(.acquire)) {
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

        if (self.stopping.load(.acquire)) {
            net.Stream.close(&stream, self.io);
            return;
        }

        // `registerClient` owns the socket from its first line and closes it on
        // every failure path, so closing it here as well would close the same
        // handle twice — and on Windows a handle can be reused in between.
        registerClient(self, stream) catch |err| {
            std.debug.print("[server] dropping connection: {s}\n", .{@errorName(err)});
        };
    }
}

fn registerClient(self: *Server, stream: net.Stream) !void {
    // The socket belongs to this function from its first line, and is closed on
    // every failure path exactly once.
    const conn = self.gpa.create(ClientConn) catch |err| {
        net.Stream.close(&stream, self.io);
        return err;
    };
    conn.* = .{ .stream = stream };

    // From here on every failure has to unwind through this: the connection
    // threads must be stopped and joined before the storage can be released.
    var reader_started = false;
    var writer_started = false;
    errdefer {
        markClosed(self, conn);
        closeStream(self, conn);
        if (reader_started) conn.reader.?.join();
        if (writer_started) conn.writer.?.join();
        conn.deinit(self.gpa);
        self.gpa.destroy(conn);
    }

    conn.read_buf = try self.gpa.alloc(u8, conn_read_size);
    conn.write_buf = try self.gpa.alloc(u8, conn_write_size);

    conn.reader = try std.Thread.spawn(.{}, readerThread, .{ self, conn });
    reader_started = true;
    conn.writer = try std.Thread.spawn(.{}, writerThread, .{ self, conn });
    writer_started = true;

    self.lock();
    defer self.unlock();
    try self.clients.append(self.arena.allocator(), conn);
}

fn readerThread(self: *Server, conn: *ClientConn) void {
    // The writer may be parked in `send`, and the connection can only be
    // released once both threads have returned.
    defer {
        markClosed(self, conn);
        _ = conn.threads_exited.fetchAdd(1, .acq_rel);
    }

    var chunk: [read_chunk_size]u8 = undefined;
    var buffers: [1][]u8 = [_][]u8{chunk[0..]};

    while (!self.stopping.load(.acquire) and !conn.closed.load(.acquire)) {
        const n = net.Stream.read(&conn.stream, self.io, &buffers) catch break;
        if (n == 0) break; // peer closed the connection
        if (!accumulateAndParse(self, conn, chunk[0..n])) break;
    }
}

fn writerThread(self: *Server, conn: *ClientConn) void {
    defer _ = conn.threads_exited.fetchAdd(1, .acq_rel);

    while (true) {
        if (conn.closed.load(.acquire)) return;

        const frame = popFrame(self, conn) orelse {
            // A permit may already be outstanding, so re-check before parking.
            if (conn.closed.load(.acquire)) return;
            conn.write_sem.wait(self.io) catch return;
            continue;
        };

        const ok = writeFrame(self.io, conn, frame.bytes);
        frame.release(self.gpa);
        if (!ok) {
            std.debug.print(
                "[server] write to player {d} failed; closing the connection\n",
                .{conn.player_id},
            );
            markClosed(self, conn);
            return;
        }
    }
}

fn popFrame(self: *Server, conn: *ClientConn) ?*Frame {
    self.lock();
    defer self.unlock();
    if (conn.outgoing.items.len == 0) return null;
    const frame = conn.outgoing.orderedRemove(0);
    conn.queued_bytes -= frame.bytes.len;
    return frame;
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

/// Decode one client frame and hand it to the right consumer.
///
/// Simulation messages go through the queue, including `C2S_HELLO`: the
/// simulation is only ever touched by the simulation thread, so a reader thread
/// can never be applying an input while a step is integrating.
///
/// `C2S_ACK_SNAPSHOT` is the exception. It names no simulation state at all —
/// it only tells the server which tick this connection holds — and the
/// broadcast has to see the newest one at the instant it encodes, so it is
/// stored here, under the lock, the moment it is decoded.
fn routeClient(self: *Server, conn: *ClientConn, msg_type: u8, payload: []const u8) void {
    if (msg_type == wire.msg.c2s_ack_snapshot) {
        const ack = wire.decodePayload(wire.AckSnapshot, payload) orelse return;
        self.lock();
        defer self.unlock();
        if (conn.closed.load(.acquire)) return;
        conn.noteAck(ack.last_recv_server_tick);
        return;
    }

    const message: Incoming = switch (msg_type) {
        wire.msg.c2s_hello => .{ .hello = wire.decodeHello(payload) orelse return },
        wire.msg.c2s_input => .{ .input = wire.decodePayload(wire.Input, payload) orelse return },
        wire.msg.c2s_levelup_choice => .{
            .levelup_choice = wire.decodePayload(wire.LevelupChoice, payload) orelse return,
        },
        wire.msg.c2s_restart => .{ .restart = {} },
        else => {
            std.debug.print(
                "[server] note: ignoring unknown message type 0x{x}\n",
                .{msg_type},
            );
            return;
        },
    };

    self.lock();
    defer self.unlock();
    if (conn.closed.load(.acquire)) return;
    conn.incoming.append(self.gpa, message) catch |e| {
        // Dropping an input would silently desynchronise the client's
        // prediction, so a queue that cannot grow ends the connection instead.
        std.debug.print(
            "[server] disconnect: out of memory queuing input from player {d}: {s}\n",
            .{ conn.player_id, @errorName(e) },
        );
        markClosed(self, conn);
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "the next tick deadline is the remainder of the interval, measured from now" {
    const tick_ns: i96 = std.time.ns_per_s / root.tick_hz;
    const previous = std.Io.Clock.Timestamp{ .raw = .{ .nanoseconds = 1_000_000_000 }, .clock = .awake };
    const now = std.Io.Clock.Timestamp{ .raw = .{ .nanoseconds = 1_005_000_000 }, .clock = .awake };
    const accumulator: i96 = 5 * std.time.ns_per_ms;

    const deadline = nextTickDeadline(now, accumulator, tick_ns);

    // 16.67 ms tick with 5 ms already spent leaves 11.67 ms, counted from now.
    try std.testing.expectEqual(
        now.raw.nanoseconds + (tick_ns - accumulator),
        deadline.raw.nanoseconds,
    );
    try std.testing.expect(deadline.raw.nanoseconds > now.raw.nanoseconds);
    // The old formula measured that remainder from the start of the frame,
    // which puts the deadline in the past and turns the wait into a busy loop.
    try std.testing.expect(deadline.raw.nanoseconds > previous.raw.nanoseconds + accumulator);

    // Nothing owed means a whole tick.
    try std.testing.expectEqual(
        now.raw.nanoseconds + tick_ns,
        nextTickDeadline(now, 0, tick_ns).raw.nanoseconds,
    );
    // An over-full accumulator can never produce a deadline in the past.
    try std.testing.expectEqual(
        now.raw.nanoseconds,
        nextTickDeadline(now, tick_ns + 1, tick_ns).raw.nanoseconds,
    );
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
    defer conn.incoming.deinit(gpa);
    defer conn.read_accum.deinit(gpa);
    try std.testing.expect(accumulateAndParse(&server, &conn, wire_bytes.items));

    try std.testing.expectEqual(@as(usize, 2), conn.incoming.items.len);
    const first = conn.incoming.items[0].input;
    try std.testing.expectEqual(@as(u32, 1), first.input_seq);
    try std.testing.expectEqual(@as(u32, 2), first.client_tick);
    try std.testing.expectEqual(@as(i8, 100), first.move_x);
    try std.testing.expectEqual(@as(i8, 0), first.move_y);
    try std.testing.expectEqual(@as(u16, 0), first.aim_angle);
    try std.testing.expectEqual(@as(u8, 0), first.buttons);
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
    defer conn.incoming.deinit(gpa);
    defer conn.read_accum.deinit(gpa);
    const all = wire_bytes.items;
    try std.testing.expect(accumulateAndParse(&server, &conn, all[0 .. all.len - 1]));
    try std.testing.expectEqual(@as(usize, 0), conn.incoming.items.len);

    // The remaining byte completes it.
    try std.testing.expect(accumulateAndParse(&server, &conn, all[all.len - 1 ..]));
    try std.testing.expectEqual(@as(usize, 1), conn.incoming.items.len);
    try std.testing.expectEqual(@as(u32, 7), conn.incoming.items[0].input.input_seq);
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
    defer conn.read_accum.deinit(gpa);
    try std.testing.expect(!accumulateAndParse(&server, &conn, wire_bytes.items));
}

test "a frame whose payload is not exactly the message size is rejected" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var server = Server.init(std.Io.failing, gpa, &arena);

    var payload = wire.Sink.init();
    defer payload.deinit(gpa);
    try payload.leU32(gpa, 1);
    try payload.leU32(gpa, 1);
    try payload.byte(gpa, 100);
    try payload.byte(gpa, 0);
    try payload.leU16(gpa, 0);
    try payload.byte(gpa, 0);
    try payload.byte(gpa, 0); // one byte too many for C2S_INPUT

    var wire_bytes = std.ArrayList(u8).empty;
    defer wire_bytes.deinit(gpa);
    try wire.writeFrame(gpa, &wire_bytes, wire.msg.c2s_input, payload.bytes(), 0);

    var conn = ClientConn{};
    defer conn.incoming.deinit(gpa);
    defer conn.read_accum.deinit(gpa);
    // The frame is well formed and within the size cap, but the payload does
    // not match C2S_INPUT, so nothing is queued.
    try std.testing.expect(accumulateAndParse(&server, &conn, wire_bytes.items));
    try std.testing.expectEqual(@as(usize, 0), conn.incoming.items.len);
}

test "the input drain applies every queued message in order" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var server = Server.init(std.Io.failing, gpa, &arena);

    var conn = ClientConn{};
    defer conn.incoming.deinit(gpa);

    // A HELLO followed by three inputs, all queued before a single step.
    const name = nameField("tester");
    try conn.incoming.append(gpa, .{ .hello = .{
        .proto_ver = root.protocol_version,
        .requested_slot = 0,
        .session_token = 0x1234,
        .name = name,
    } });
    for ([_]u32{ 1, 2, 3 }) |seq| {
        try conn.incoming.append(gpa, .{ .input = .{
            .input_seq = seq,
            .client_tick = seq,
            .move_x = 100,
        } });
    }

    server.lock();
    while (conn.incoming.items.len > 0) {
        const message = conn.incoming.orderedRemove(0);
        dispatch(&server, &conn, message);
    }
    server.unlock();

    // Nothing was dropped on the way through, and the last input is the one the
    // client will be told about.
    try std.testing.expectEqual(@as(usize, 0), conn.incoming.items.len);
    try std.testing.expectEqual(@as(u8, 0), conn.player_id);
    try std.testing.expectEqual(@as(u32, 3), server.sim.players[0].last_input_seq);

    // The two frames queued by the handshake are released with the connection.
    for (conn.outgoing.items) |frame| frame.release(gpa);
    conn.outgoing.deinit(gpa);
}

test "a handshake queues a welcome and an immediate full snapshot" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var server = Server.init(std.Io.failing, gpa, &arena);

    const conn = try gpa.create(ClientConn);
    conn.* = .{};
    defer gpa.destroy(conn);
    defer conn.outgoing.deinit(gpa);
    defer conn.incoming.deinit(gpa);

    var payload = wire.Sink.init();
    defer payload.deinit(gpa);
    try payload.byte(gpa, 1); // proto_ver
    try payload.byte(gpa, 0); // requested_slot
    try payload.leU64(gpa, 0xdeadbeef); // session_token
    try payload.fixedBytes(gpa, &nameField("tester"));

    routeClient(&server, conn, wire.msg.c2s_hello, payload.bytes());
    // HELLO is queued, not dispatched: the simulation is the simulation
    // thread's alone.
    try std.testing.expectEqual(@as(usize, 1), conn.incoming.items.len);
    try std.testing.expectEqual(@as(usize, 0), conn.outgoing.items.len);

    dispatch(&server, conn, conn.incoming.orderedRemove(0));

    try std.testing.expectEqual(@as(u8, 0), conn.player_id);
    try std.testing.expectEqual(@as(u64, 0xdeadbeef), conn.session_token);
    // Welcome, the immediate full snapshot, and the loadout the HUD needs.
    try std.testing.expectEqual(@as(usize, 3), conn.outgoing.items.len);

    const welcome = wire.decodeFrameHeader(conn.outgoing.items[0].bytes).?;
    try std.testing.expectEqual(wire.msg.s2c_welcome, welcome.msg_type);
    const snapshot = wire.decodeFrameHeader(conn.outgoing.items[1].bytes).?;
    try std.testing.expectEqual(wire.msg.s2c_snapshot_full, snapshot.msg_type);
    const loadout = wire.decodeFrameHeader(conn.outgoing.items[2].bytes).?;
    try std.testing.expectEqual(wire.msg.s2c_loadout, loadout.msg_type);

    for (conn.outgoing.items) |frame| frame.release(gpa);
}

test "a HELLO with the wrong protocol version is refused" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var server = Server.init(std.Io.failing, gpa, &arena);

    const conn = try gpa.create(ClientConn);
    conn.* = .{};
    defer gpa.destroy(conn);
    defer conn.outgoing.deinit(gpa);
    defer conn.incoming.deinit(gpa);

    var payload = wire.Sink.init();
    defer payload.deinit(gpa);
    try payload.byte(gpa, 2);
    try payload.byte(gpa, 0);
    try payload.leU64(gpa, 1);
    try payload.fixedBytes(gpa, &nameField(""));

    routeClient(&server, conn, wire.msg.c2s_hello, payload.bytes());
    dispatch(&server, conn, conn.incoming.orderedRemove(0));

    try std.testing.expect(conn.closed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), conn.outgoing.items.len);
}

test "a broadcast gives each connection its own snapshot frame" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var server = Server.init(std.Io.failing, gpa, &arena);

    // Two connections, both past the handshake, so both are eligible. Neither
    // has acknowledged a baseline, so both get a full snapshot.
    var conns: [2]*ClientConn = undefined;
    for (&conns) |*slot| {
        const conn = try gpa.create(ClientConn);
        conn.* = .{ .player_id = 0 };
        slot.* = conn;
    }
    defer for (conns) |conn| {
        conn.deinit(gpa);
        gpa.destroy(conn);
    };
    try server.clients.append(arena.allocator(), conns[0]);
    try server.clients.append(arena.allocator(), conns[1]);

    _ = server.sim.spawnPlayer(0);
    server.broadcast();

    // Each connection gets its own frame now: a delta is diffed against that
    // connection's baseline and filtered to its neighbourhood, so two clients
    // rarely want the same bytes. Each frame has one reference, owned by its
    // connection, and the release is the one that frees it.
    // `std.testing.allocator` fails the test on a double free or a leak.
    try std.testing.expectEqual(@as(usize, 1), conns[0].outgoing.items.len);
    try std.testing.expectEqual(@as(usize, 1), conns[1].outgoing.items.len);
    try std.testing.expect(conns[0].outgoing.items[0] != conns[1].outgoing.items[0]);
    for (conns) |conn| {
        const frame = conn.outgoing.items[0];
        try std.testing.expectEqual(@as(u32, 1), frame.refs.load(.acquire));
        const header = wire.decodeFrameHeader(frame.bytes).?;
        try std.testing.expectEqual(wire.msg.s2c_snapshot_full, header.msg_type);
        try std.testing.expectEqual(frame.bytes.len, conn.queued_bytes);
        frame.release(gpa);
        conn.outgoing.clearRetainingCapacity();
    }
}

test "a broadcast with no eligible connection frees its frame" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var server = Server.init(std.Io.failing, gpa, &arena);

    // No clients at all, then one that has not completed its handshake.
    server.broadcast();
    const conn = try gpa.create(ClientConn);
    conn.* = .{};
    defer gpa.destroy(conn);
    defer conn.deinit(gpa);
    try server.clients.append(arena.allocator(), conn);

    // `std.testing.allocator` reports the frame as a leak if it is not freed.
    server.broadcast();
    try std.testing.expectEqual(@as(usize, 0), conn.outgoing.items.len);
}

test "an outgoing queue that overflows drops the connection instead of growing" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var server = Server.init(std.Io.failing, gpa, &arena);

    const conn = try gpa.create(ClientConn);
    conn.* = .{ .player_id = 0 };
    defer gpa.destroy(conn);
    defer conn.deinit(gpa);
    try server.clients.append(arena.allocator(), conn);
    _ = server.sim.spawnPlayer(0);

    server.broadcast();
    // Each broadcast adds one frame; the bound is what stops a peer that never
    // reads from making the server allocate without limit.
    var i: usize = 0;
    while (i < max_queued_frames * 4) : (i += 1) server.broadcast();

    try std.testing.expect(conn.outgoing.items.len <= max_queued_frames);
    try std.testing.expect(conn.queued_bytes <= max_queued_bytes);
    try std.testing.expect(conn.closed.load(.acquire));
}

// ---------------------------------------------------------------------------
// Loopback tests
// ---------------------------------------------------------------------------

const Loopback = struct {
    threaded: std.Io.Threaded,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    server: Server,
    port: u16,

    fn start(gpa: std.mem.Allocator) !*Loopback {
        const self = try gpa.create(Loopback);
        self.threaded = .init(gpa, .{});
        self.io = self.threaded.io();
        self.arena = std.heap.ArenaAllocator.init(gpa);
        self.server = Server.init(self.io, gpa, &self.arena);
        try self.server.listen(0);
        self.port = self.server.listener.socket.address.getPort();
        return self;
    }

    fn stop(self: *Loopback, gpa: std.mem.Allocator) void {
        self.server.shutdown();
        self.arena.deinit();
        self.threaded.deinit();
        gpa.destroy(self);
    }

    fn connect(self: *Loopback) !net.Stream {
        return net.IpAddress.connect(
            &.{ .ip4 = net.Ip4Address.loopback(self.port) },
            self.io,
            .{ .mode = .stream, .protocol = .tcp },
        );
    }
};

/// A connected loopback client with a frame reader over its socket.
///
/// Initialised in place: `net.Stream.Reader`/`Writer` keep a slice of the
/// caller's buffer, so copying the struct would leave them pointing at the
/// frame that built it.
const TestClient = struct {
    stream: ?net.Stream = null,
    io: std.Io = undefined,
    gpa: std.mem.Allocator = undefined,
    wbuf: [0]u8 = .{},
    writer: net.Stream.Writer = undefined,
    rbuf: [1024]u8 = undefined,
    reader: net.Stream.Reader = undefined,
    slice: [1][]u8 = undefined,

    fn init(self: *TestClient, loop: *Loopback, gpa: std.mem.Allocator) !void {
        self.io = loop.io;
        self.gpa = gpa;
        self.stream = try loop.connect();
        self.writer = net.Stream.writer(self.stream.?, loop.io, &self.wbuf);
        self.reader = net.Stream.reader(self.stream.?, loop.io, &self.rbuf);
    }

    /// Idempotent: a test may close early and still have the cleanup defer run.
    fn close(self: *TestClient) void {
        const stream = self.stream orelse return;
        self.stream = null;
        net.Stream.close(&stream, self.io);
    }

    /// Send a `C2S_HELLO` for `name`.
    fn hello(self: *TestClient, name: []const u8, token: u64) !void {
        var payload = wire.Sink.init();
        defer payload.deinit(self.gpa);
        try payload.byte(self.gpa, root.protocol_version);
        try payload.byte(self.gpa, 0);
        try payload.leU64(self.gpa, token);
        try payload.fixedBytes(self.gpa, &nameField(name));
        const frame = try wire.encodeFrame(self.gpa, wire.msg.c2s_hello, payload.bytes(), 0);
        defer self.gpa.free(frame);
        try self.writer.interface.writeAll(frame);
        try std.Io.Writer.flush(&self.writer.interface);
    }

    /// Send a `C2S_INPUT` holding `move_x` for one tick.
    fn input(self: *TestClient, seq: u32, move_x: i8) !void {
        var payload = wire.Sink.init();
        defer payload.deinit(self.gpa);
        try payload.leU32(self.gpa, seq);
        try payload.leU32(self.gpa, seq);
        try payload.byte(self.gpa, @as(u8, @bitCast(move_x)));
        try payload.byte(self.gpa, 0);
        try payload.leU16(self.gpa, 0);
        try payload.byte(self.gpa, 0);
        const frame = try wire.encodeFrame(self.gpa, wire.msg.c2s_input, payload.bytes(), seq);
        defer self.gpa.free(frame);
        try self.writer.interface.writeAll(frame);
        try std.Io.Writer.flush(&self.writer.interface);
    }

    /// Send a `C2S_LEVELUP_CHOICE` for `event_id`.
    fn levelupChoice(self: *TestClient, event_id: u16, choice_idx: u8) !void {
        var payload = wire.Sink.init();
        defer payload.deinit(self.gpa);
        try payload.leU16(self.gpa, event_id);
        try payload.byte(self.gpa, choice_idx);
        const frame = try wire.encodeFrame(self.gpa, wire.msg.c2s_levelup_choice, payload.bytes(), 0);
        defer self.gpa.free(frame);
        try self.writer.interface.writeAll(frame);
        try std.Io.Writer.flush(&self.writer.interface);
    }

    /// Send a `C2S_ACK_SNAPSHOT` for `server_tick`.
    fn ack(self: *TestClient, server_tick: u32) !void {
        var payload = wire.Sink.init();
        defer payload.deinit(self.gpa);
        try payload.leU32(self.gpa, server_tick);
        const frame = try wire.encodeFrame(self.gpa, wire.msg.c2s_ack_snapshot, payload.bytes(), 0);
        defer self.gpa.free(frame);
        try self.writer.interface.writeAll(frame);
        try std.Io.Writer.flush(&self.writer.interface);
    }

    /// Send a `C2S_RESTART`.
    fn restart(self: *TestClient) !void {
        const frame = try wire.encodeFrame(self.gpa, wire.msg.c2s_restart, &.{}, 0);
        defer self.gpa.free(frame);
        try self.writer.interface.writeAll(frame);
        try std.Io.Writer.flush(&self.writer.interface);
    }

    /// Read one complete frame. Bounded to the bytes still needed: `readVec`
    /// will happily return more than asked for, and a read that runs past the
    /// frame boundary would consume the next frame's bytes and lose them.
    fn readFrame(self: *TestClient, buf: []u8) ![]u8 {
        var filled: usize = 0;
        while (filled < wire.header_size) {
            self.slice[0] = buf[filled..wire.header_size];
            const n = self.reader.interface.readVec(&self.slice) catch return error.EndOfStream;
            if (n == 0) return error.EndOfStream;
            filled += n;
        }
        const header = wire.decodeFrameHeader(buf[0..wire.header_size]).?;
        const total = wire.header_size + header.payload_len;
        while (filled < total) {
            self.slice[0] = buf[filled..total];
            const n = self.reader.interface.readVec(&self.slice) catch return error.EndOfStream;
            if (n == 0) return error.EndOfStream;
            filled += n;
        }
        return buf[0..total];
    }

    /// Read frames into `buf` until one of type `want_msg` arrives, then return
    /// it. The frame is a slice of `buf`, which the caller owns.
    fn expectFrame(self: *TestClient, buf: []u8, want_msg: u8, limit: usize) ![]u8 {
        var i: usize = 0;
        while (i < limit) : (i += 1) {
            const frame = try self.readFrame(buf);
            const header = wire.decodeFrameHeader(frame).?;
            if (header.msg_type == want_msg) return frame;
        }
        return error.FrameNeverArrived;
    }
};

/// Spin until `clients` holds `want` connections, yielding so the accept thread
/// gets a chance to run. Fails the test rather than spinning forever.
fn waitForClients(server: *Server, want: usize) !void {
    var spins: usize = 0;
    while (spins < 2_000_000) : (spins += 1) {
        if (server.clientCount() >= want) return;
        std.Thread.yield() catch {};
    }
    return error.ClientNeverAccepted;
}

/// Spin until the reader threads have queued `want` messages in total.
fn waitForIncoming(server: *Server, want: usize) !void {
    var spins: usize = 0;
    while (spins < 2_000_000) : (spins += 1) {
        server.lock();
        var total: usize = 0;
        for (server.clients.items) |conn| total += conn.incoming.items.len;
        server.unlock();
        if (total >= want) return;
        std.Thread.yield() catch {};
    }
    return error.MessageNeverArrived;
}

/// Spin until every accepted connection has acknowledged `tick`.
///
/// An acknowledgement is applied by the reader thread the moment it is decoded
/// rather than queued for the simulation thread, so there is nothing for
/// `waitForIncoming` to count: the atomic the reader stored is what a test has
/// to watch.
fn waitForAck(server: *Server, tick: u32) !void {
    var spins: usize = 0;
    while (spins < 2_000_000) : (spins += 1) {
        server.lock();
        var seen: usize = 0;
        var done = true;
        for (server.clients.items) |conn| {
            seen += 1;
            if (conn.acked_tick.load(.acquire) != tick) done = false;
        }
        server.unlock();
        if (done and seen > 0) return;
        std.Thread.yield() catch {};
    }
    return error.AckNeverArrived;
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

/// Read every frame the server has queued for `client` but that the test has
/// not read yet, recording the last `pos_x` any snapshot carried.
///
/// The count is exact rather than a guess: the server sends two frames on the
/// handshake (the welcome and an immediate full snapshot) and one more on every
/// broadcast tick, so a read can never run past what has actually been sent and
/// block.
fn readNewFrames(
    client: *TestClient,
    buf: []u8,
    sent: *usize,
    tick: u32,
    last_pos_x: *i16,
) !void {
    const want = 3 + tick / root.ticks_per_snapshot;
    while (sent.* < want) : (sent.* += 1) {
        const frame = try client.readFrame(buf);
        const header = wire.decodeFrameHeader(frame).?;
        if (header.msg_type != wire.msg.s2c_snapshot_full) continue;
        const payload = frame[wire.header_size..];
        if (payload.len < wire.snapshot_header_wire_size + wire.wireSize(wire.PlayerNet)) continue;
        const record = payload[wire.snapshot_header_wire_size..];
        last_pos_x.* = std.mem.bytesToValue(i16, record[2..4]);
    }
}

test "a loopback connection completes HELLO, INPUT and SNAPSHOT_FULL" {
    const gpa = std.testing.allocator;
    const loop = try Loopback.start(gpa);
    defer loop.stop(gpa);

    var client: TestClient = .{};
    try client.init(loop, gpa);
    defer client.close();

    try client.hello("tester", 0x1234);
    try waitForClients(&loop.server, 1);
    try waitForIncoming(&loop.server, 1);

    // HELLO is dispatched by the step, which is also what queues the welcome
    // and the immediate full snapshot.
    loop.server.step();
    try std.testing.expect(loop.server.sim.players[0].active);
    var got: [1024]u8 = undefined;
    _ = try client.expectFrame(&got, wire.msg.s2c_welcome, 4);

    try client.input(1, 100);
    try waitForIncoming(&loop.server, 1);
    // The first step applies the input and integrates it; the next two reach
    // tick 3, which is the first tick that broadcasts a snapshot of the moved
    // player. The handshake's own snapshot and that one are the only two frames
    // on the wire, so the reads below cannot block.
    loop.server.step();
    try std.testing.expectEqual(@as(u8, 0), loop.server.sim.players[0].id);
    try std.testing.expectEqual(@as(u32, 1), loop.server.sim.players[0].last_input_seq);
    try std.testing.expectEqual(
        @as(u8, @bitCast(loop.server.sim.players[0].input.move_x)),
        100,
    );
    try std.testing.expect(loop.server.sim.players[0].pos[0] > 0);
    loop.server.step();
    loop.server.step();

    // The writer thread sends what the steps queued; the snapshot taken after
    // the input carries the moved position.
    // The handshake queued a welcome, an immediate full snapshot and a
    // loadout; the tick-3 snapshot is the one that carries the movement.
    var seen_movement = false;
    for (0..3) |_| {
        const frame = try client.readFrame(&got);
        if (snapshotShowsMovement(frame)) seen_movement = true;
    }
    try std.testing.expect(seen_movement);
}

test "two clients each receive the snapshots, and one leaving does not disturb the other" {
    const gpa = std.testing.allocator;
    const loop = try Loopback.start(gpa);
    defer loop.stop(gpa);

    var first: TestClient = .{};
    try first.init(loop, gpa);
    defer first.close();
    var second: TestClient = .{};
    try second.init(loop, gpa);
    defer second.close();

    try first.hello("first", 0xaaaa);
    try second.hello("second", 0xbbbb);
    try waitForClients(&loop.server, 2);
    try waitForIncoming(&loop.server, 2);
    loop.server.step();

    // Both handshakes were served and each client got its own welcome with its
    // own player id.
    try std.testing.expectEqual(@as(u8, 2), loop.server.sim.activePlayerCount());
    var got_a: [1024]u8 = undefined;
    var got_b: [1024]u8 = undefined;
    const first_welcome = try first.expectFrame(&got_a, wire.msg.s2c_welcome, 2);
    const first_id = first_welcome[wire.header_size];
    const second_welcome = try second.expectFrame(&got_b, wire.msg.s2c_welcome, 2);
    const second_id = second_welcome[wire.header_size];
    try std.testing.expect(first_id != second_id);

    // Each handshake also queued an immediate full snapshot and a loadout, both
    // of which have to come off the socket for the frame accounting below to
    // stay in step.
    _ = try first.readFrame(&got_a);
    _ = try first.readFrame(&got_a);
    _ = try second.readFrame(&got_b);
    _ = try second.readFrame(&got_b);

    var sent_a: usize = 3;
    var sent_b: usize = 3;
    var pos_x_a: i16 = 0;
    var pos_x_b: i16 = 0;

    // Drive both clients and check that both keep receiving snapshots. The two
    // consumers share one frame, so the first one to finish with it must not
    // free bytes the other is still reading; `std.testing.allocator` reports a
    // double free or a use-after-free here.
    for (1..4) |seq| {
        try first.input(@intCast(seq), 100);
        try second.input(@intCast(seq), 100);
    }
    try waitForIncoming(&loop.server, 6);
    for (0..4) |_| loop.server.step();
    try readNewFrames(&first, &got_a, &sent_a, loop.server.sim.tick, &pos_x_a);
    try readNewFrames(&second, &got_b, &sent_b, loop.server.sim.tick, &pos_x_b);
    try std.testing.expect(sent_a > 2 and sent_b > 2);
    try std.testing.expect(pos_x_a > 0 and pos_x_b > 0);

    // Retire the first client. The second one's storage must not have moved and
    // its writer must still be draining, so it keeps receiving snapshots.
    first.close();
    var spins: usize = 0;
    while (loop.server.clientCount() > 1 and spins < 200) : (spins += 1) {
        loop.server.step();
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), loop.server.clientCount());
    try std.testing.expectEqual(@as(u8, 1), loop.server.sim.activePlayerCount());
    try std.testing.expect(!loop.server.sim.players[first_id].active);
    try std.testing.expect(loop.server.sim.players[second_id].active);
    try readNewFrames(&second, &got_b, &sent_b, loop.server.sim.tick, &pos_x_b);
    const turned_at = pos_x_b;

    for (4..7) |seq| {
        try second.input(@intCast(seq), -100);
    }
    try waitForIncoming(&loop.server, 3);
    for (0..6) |_| loop.server.step();

    // The surviving player is the one that has now turned around, and it is
    // still the only player in the snapshot.
    try readNewFrames(&second, &got_b, &sent_b, loop.server.sim.tick, &pos_x_b);
    try std.testing.expect(pos_x_b < turned_at);
}

test "a client that stops reading cannot stall the tick" {
    const gpa = std.testing.allocator;
    const loop = try Loopback.start(gpa);
    defer loop.stop(gpa);

    var client: TestClient = .{};
    try client.init(loop, gpa);
    // Registered after `loop.stop`, so it runs first: closing our end makes the
    // reader thread's `recv` return and lets shutdown join it.
    defer client.close();

    try client.hello("silent", 0xcccc);
    try waitForClients(&loop.server, 1);
    try waitForIncoming(&loop.server, 1);
    loop.server.step();

    // The client now stops reading, and the queue is filled past the socket
    // buffer so the writer thread parks inside `send`.
    const conn = loop.server.clients.items[0];
    var backlog: usize = 0;
    while (backlog < 8 * 1024 * 1024) {
        const bytes = try gpa.alloc(u8, 64 * 1024);
        @memset(bytes, 0);
        const frame = try Frame.create(gpa, bytes);
        loop.server.lock();
        conn.outgoing.append(gpa, frame) catch |e| {
            loop.server.unlock();
            frame.release(gpa);
            return e;
        };
        conn.queued_bytes += frame.bytes.len;
        loop.server.unlock();
        backlog += frame.bytes.len;
    }
    conn.write_sem.post(loop.io);
    std.Io.sleep(loop.io, .{ .nanoseconds = 200 * std.time.ns_per_ms }, .awake) catch {};

    // The writer is stuck with work left, so anything the tick does with the
    // socket would stall here.
    loop.server.lock();
    const still_queued = conn.queued_bytes;
    loop.server.unlock();
    try std.testing.expect(still_queued > 0);

    const before = std.Io.Clock.Timestamp.now(loop.io, .awake);
    for (0..120) |_| loop.server.step();
    const after = std.Io.Clock.Timestamp.now(loop.io, .awake);
    const elapsed_ms = @divTrunc(before.durationTo(after).raw.nanoseconds, @as(i96, std.time.ns_per_ms));
    // 120 steps of an empty simulation: the only cost is encoding a snapshot
    // every third tick. Two seconds is a generous ceiling that a blocked socket
    // write would blow straight through.
    try std.testing.expect(elapsed_ms < 2000);
}

test "a level-up offer goes out, the choice is applied, and the loadout follows" {
    const gpa = std.testing.allocator;
    const loop = try Loopback.start(gpa);
    defer loop.stop(gpa);

    var client: TestClient = .{};
    try client.init(loop, gpa);
    defer client.close();

    try client.hello("tester", 0x1234);
    try waitForClients(&loop.server, 1);
    try waitForIncoming(&loop.server, 1);
    loop.server.step();

    var got: [2048]u8 = undefined;
    _ = try client.expectFrame(&got, wire.msg.s2c_welcome, 4);
    // The handshake also queued an immediate full snapshot and a loadout.
    _ = try client.readFrame(&got);
    _ = try client.readFrame(&got);

    // Fill the XP bar; the next step offers the level-up and pauses.
    loop.server.sim.players[0].xp = loop.server.sim.players[0].xp_next;
    loop.server.step();
    try std.testing.expectEqual(sim.GameState.level_up_pause, loop.server.sim.state);

    const offer = try client.expectFrame(&got, wire.msg.s2c_levelup_offer, 8);
    const ev = wire.decodePayload(wire.LevelupOffer, offer[wire.header_size..]).?;
    try std.testing.expectEqual(@as(u16, 2), ev.new_level);
    // Three distinct options.
    try std.testing.expect(ev.opt0_item_id != ev.opt1_item_id);
    try std.testing.expect(ev.opt1_item_id != ev.opt2_item_id);
    try std.testing.expect(ev.opt0_item_id != ev.opt2_item_id);

    // Answer it, and the run resumes with the loadout the HUD needs.
    try client.levelupChoice(ev.event_id, 0);
    try waitForIncoming(&loop.server, 1);
    loop.server.step();
    try std.testing.expectEqual(sim.GameState.running, loop.server.sim.state);

    const loadout = try client.expectFrame(&got, wire.msg.s2c_loadout, 8);
    const l = wire.decodePayload(wire.Loadout, loadout[wire.header_size..]).?;
    try std.testing.expectEqual(@as(u16, 2), l.level);
    try std.testing.expect(l.weapon_count > 0);
}

test "game over goes out, and a restart returns to a running game" {
    const gpa = std.testing.allocator;
    const loop = try Loopback.start(gpa);
    defer loop.stop(gpa);

    var client: TestClient = .{};
    try client.init(loop, gpa);
    defer client.close();

    try client.hello("tester", 0x5678);
    try waitForClients(&loop.server, 1);
    try waitForIncoming(&loop.server, 1);
    loop.server.step();

    var got: [2048]u8 = undefined;
    _ = try client.expectFrame(&got, wire.msg.s2c_welcome, 4);
    _ = try client.readFrame(&got);
    _ = try client.readFrame(&got);

    // One swarmer on top of a 1 HP player ends the run.
    loop.server.sim.players[0].hp = 1.0;
    _ = loop.server.sim.enemies.spawn(.circle_t1, .{ 0.6, 0.0 }).?;
    var ticks: usize = 0;
    while (loop.server.sim.state != .game_over and ticks < 600) : (ticks += 1) {
        loop.server.step();
    }
    try std.testing.expectEqual(sim.GameState.game_over, loop.server.sim.state);
    try std.testing.expect(!loop.server.sim.players[0].flags.alive);

    const over = try client.expectFrame(&got, wire.msg.s2c_game_over, 8);
    const go = wire.decodePayload(wire.GameOver, over[wire.header_size..]).?;
    try std.testing.expect(go.final_tick > 0);
    try std.testing.expect(go.score > 0);

    // Restart: the run is fresh and the snapshot says so.
    try client.restart();
    try waitForIncoming(&loop.server, 1);
    loop.server.step();
    try std.testing.expectEqual(sim.GameState.running, loop.server.sim.state);
    try std.testing.expect(loop.server.sim.players[0].flags.alive);
    try std.testing.expectEqual(@as(u16, 1), loop.server.sim.players[0].level);
    try std.testing.expectEqual(@as(usize, 0), loop.server.sim.enemies.count);

    const view = loop.server.sim.snapshotView();
    try std.testing.expectEqual(@as(u8, @intFromEnum(sim.GameState.running)), view.game_state);
}

test "a client that acknowledges a baseline gets a delta against it" {
    const gpa = std.testing.allocator;
    const loop = try Loopback.start(gpa);
    defer loop.stop(gpa);

    var client: TestClient = .{};
    try client.init(loop, gpa);
    defer client.close();

    try client.hello("tester", 0x1234);
    try waitForClients(&loop.server, 1);
    try waitForIncoming(&loop.server, 1);
    loop.server.step();

    var got: [4096]u8 = undefined;
    _ = try client.expectFrame(&got, wire.msg.s2c_welcome, 4);
    const full = try client.expectFrame(&got, wire.msg.s2c_snapshot_full, 4);
    _ = try client.readFrame(&got); // loadout

    // The handshake's immediate full snapshot is at tick 0, which is not a
    // valid delta baseline. Acknowledging it gets a full snapshot back.
    const full_payload = full[wire.header_size..];
    const full_tick = wire.readLe(u32, full_payload, 0);
    try client.ack(full_tick);
    try waitForAck(&loop.server, full_tick);

    // Step to the first broadcast tick (3): a full snapshot, because tick 0 is
    // not a baseline the ring holds.
    loop.server.step();
    loop.server.step();
    const full2 = try client.expectFrame(&got, wire.msg.s2c_snapshot_full, 4);
    const full2_payload = full2[wire.header_size..];
    const full2_tick = wire.readLe(u32, full2_payload, 0);
    try std.testing.expect(full2_tick != 0);
    try std.testing.expectEqual(@as(u32, 0), wire.readLe(u32, full2_payload, 4)); // baseline_tick = 0

    // Acknowledge the tick-3 full snapshot. The next broadcast is a delta
    // against it.
    try client.ack(full2_tick);
    try waitForAck(&loop.server, full2_tick);
    loop.server.step();
    loop.server.step();
    loop.server.step();

    const d = try client.expectFrame(&got, wire.msg.s2c_snapshot_delta, 4);
    const d_payload = d[wire.header_size..];
    try std.testing.expectEqual(full2_tick, wire.readLe(u32, d_payload, 4)); // baseline_tick
    try std.testing.expectEqual(wire.readLe(u32, d_payload, 0), full2_tick + root.ticks_per_snapshot);
}

test "a delta baseline the ring no longer holds falls back to a full snapshot" {
    const gpa = std.testing.allocator;
    const loop = try Loopback.start(gpa);
    defer loop.stop(gpa);

    var client: TestClient = .{};
    try client.init(loop, gpa);
    defer client.close();

    try client.hello("tester", 0x1234);
    try waitForClients(&loop.server, 1);
    try waitForIncoming(&loop.server, 1);
    loop.server.step();

    var got: [4096]u8 = undefined;
    _ = try client.expectFrame(&got, wire.msg.s2c_welcome, 4);
    _ = try client.readFrame(&got); // immediate full snapshot
    _ = try client.readFrame(&got); // loadout

    // Acknowledge a tick far outside the 32-snapshot window: the server must
    // answer with a full snapshot, not a delta against a stale baseline.
    try client.ack(30 * root.ticks_per_snapshot);
    try waitForAck(&loop.server, 30 * root.ticks_per_snapshot);
    loop.server.step();
    loop.server.step();

    const full = try client.expectFrame(&got, wire.msg.s2c_snapshot_full, 4);
    const full_payload = full[wire.header_size..];
    try std.testing.expectEqual(@as(u32, 0), wire.readLe(u32, full_payload, 4)); // baseline_tick = 0
}

test "the held-state model follows a forward acknowledgement" {
    var conn: ClientConn = .{};

    // Nothing acknowledged yet: no state the client is known to hold.
    try std.testing.expectEqual(@as(u32, 0), conn.held_tick.load(.acquire));

    // The first ack seeds it.
    conn.noteAck(30);
    try std.testing.expectEqual(@as(u32, 30), conn.held_tick.load(.acquire));

    // Acks that run ahead of the model move it forward.
    conn.noteAck(33);
    try std.testing.expectEqual(@as(u32, 33), conn.held_tick.load(.acquire));
    conn.noteAck(36);
    try std.testing.expectEqual(@as(u32, 36), conn.held_tick.load(.acquire));

    // The model then carries itself forward onto the snapshots it sends, which
    // is what `snapshotFrame` does: each send advances the model to its own
    // tick and records the tick it left behind as the baseline the next ack is
    // measured against. Two sends take it from 36 to 42.
    conn.held_baseline.store(36, .release);
    conn.held_tick.store(39, .release);
    conn.held_baseline.store(39, .release);
    conn.held_tick.store(42, .release);

    // The ack that send left in flight names the baseline it was diffed
    // against — the client holds it until it processes that snapshot — and it
    // must not drag the model backwards.
    conn.noteAck(39);
    try std.testing.expectEqual(@as(u32, 42), conn.held_tick.load(.acquire));

    // Repeating it is not lag, it is the client refusing and re-acknowledging:
    // that is the drift correction, and it is the test below.
    conn.noteAck(39);
    try std.testing.expectEqual(@as(u32, 39), conn.held_tick.load(.acquire));
}

test "a repeated acknowledgement pulls a model that ran ahead back" {
    var conn: ClientConn = .{};
    conn.noteAck(30);

    // The model advances the way `snapshotFrame` does, onto each snapshot it
    // sends, without any further acknowledgement.
    conn.held_baseline.store(42, .release);
    conn.held_tick.store(45, .release);

    // An ack naming the baseline the last snapshot was diffed against is that
    // snapshot's own send coming back: lag, not correction.
    conn.noteAck(42);
    try std.testing.expectEqual(@as(u32, 45), conn.held_tick.load(.acquire));

    // Repeating it means the client refused the delta the model expected it to
    // apply and is re-acknowledging the state it really holds: without this the
    // model would refuse forever.
    conn.noteAck(42);
    try std.testing.expectEqual(@as(u32, 42), conn.held_tick.load(.acquire));
}

test "a corrected model rebuilds the held state from the ring" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var server = Server.init(std.Io.failing, gpa, &arena);

    // A player with a neighbourhood: one enemy in interest, one far outside it.
    const p = server.sim.spawnPlayer(0).?;
    p.pos = .{ 0.0, 0.0 };
    _ = server.sim.enemies.spawn(.circle_t1, .{ 5.0, 0.0 }).?;
    _ = server.sim.enemies.spawn(.circle_t1, .{ 500.0, 0.0 }).?;

    server.sim.tick = 30;
    server.snapshots.store(server.sim.snapshotView());

    var conn = ClientConn{ .player_id = 0 };

    // Tick 0 is never a model, and neither is a tick the ring never stored.
    try std.testing.expect(!server.syncHeld(&conn, 0));
    try std.testing.expect(!server.syncHeld(&conn, 27));

    // A tick the ring holds: the state is rebuilt from it, filtered to the
    // receiver's own neighbourhood rather than to the whole world.
    try std.testing.expect(server.syncHeld(&conn, 30));
    try std.testing.expectEqual(@as(u32, 30), conn.held_tick_content);
    try std.testing.expectEqual(@as(u16, 1), conn.held.counts[1]);
    try std.testing.expectEqual(@as(u32, 1), conn.held.enemies[0].id);

    // Already in line: a no-op that stays true.
    try std.testing.expect(server.syncHeld(&conn, 30));

    // A tick that has fallen out of the 32-snapshot window is no model either.
    server.sim.tick = 30 + delta.ring_size * root.ticks_per_snapshot;
    server.snapshots.store(server.sim.snapshotView());
    try std.testing.expect(!server.syncHeld(&conn, 30));
}

test "a delta is diffed against the held state, not the last acknowledgement" {
    const gpa = std.testing.allocator;
    const loop = try Loopback.start(gpa);
    defer loop.stop(gpa);

    var client: TestClient = .{};
    try client.init(loop, gpa);
    defer client.close();

    try client.hello("tester", 0x1234);
    try waitForClients(&loop.server, 1);
    try waitForIncoming(&loop.server, 1);
    loop.server.step();

    var got: [4096]u8 = undefined;
    _ = try client.expectFrame(&got, wire.msg.s2c_welcome, 4);
    _ = try client.readFrame(&got); // immediate full snapshot
    _ = try client.readFrame(&got); // loadout

    // Reach the first broadcast tick and acknowledge the full snapshot it sends.
    loop.server.step();
    loop.server.step();
    const first = try client.expectFrame(&got, wire.msg.s2c_snapshot_full, 4);
    const first_tick = wire.readLe(u32, first[wire.header_size..], 0);
    try client.ack(first_tick);
    try waitForAck(&loop.server, first_tick);

    // From here the client acknowledges nothing more. The server still carries
    // the held state forward, so every delta names the snapshot the client is
    // holding rather than the one it last acknowledged: with the ack alone as
    // the baseline, every delta after the first would name `first_tick` again.
    var expected_baseline = first_tick;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        loop.server.step();
        loop.server.step();
        loop.server.step();
        const d = try client.expectFrame(&got, wire.msg.s2c_snapshot_delta, 4);
        const payload = d[wire.header_size..];
        try std.testing.expectEqual(expected_baseline, wire.readLe(u32, payload, 4));
        try std.testing.expectEqual(
            expected_baseline + root.ticks_per_snapshot,
            wire.readLe(u32, payload, 0),
        );
        expected_baseline += root.ticks_per_snapshot;
    }
}

test "the first corrective acknowledgement pulls the model back" {
    const gpa = std.testing.allocator;
    const loop = try Loopback.start(gpa);
    defer loop.stop(gpa);

    var client: TestClient = .{};
    try client.init(loop, gpa);
    defer client.close();

    try client.hello("tester", 0x1234);
    try waitForClients(&loop.server, 1);
    try waitForIncoming(&loop.server, 1);
    loop.server.step();

    var got: [4096]u8 = undefined;
    _ = try client.expectFrame(&got, wire.msg.s2c_welcome, 4);
    _ = try client.readFrame(&got); // immediate full snapshot
    _ = try client.readFrame(&got); // loadout

    // Reach the first broadcast tick and acknowledge the full snapshot it sends:
    // the model seeds from that ack.
    loop.server.step();
    loop.server.step();
    const first = try client.expectFrame(&got, wire.msg.s2c_snapshot_full, 4);
    const first_tick = wire.readLe(u32, first[wire.header_size..], 0);
    try client.ack(first_tick);
    try waitForAck(&loop.server, first_tick);

    // The client then acknowledges nothing for three broadcasts while the
    // server carries the model forward onto each snapshot it sends, so the
    // model runs ahead of the tick the client really holds.
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        loop.server.step();
        loop.server.step();
        loop.server.step();
    }
    const held = first_tick + 3 * root.ticks_per_snapshot;

    // The client's first corrective ack names a tick it does hold, behind the
    // model and — this is the case the old predicate got wrong — different from
    // the ack before it, so the repeat test could not see it. It is also older
    // than the baseline of the most recent snapshot, so it is not an ack still
    // in flight either: it is a state the model cannot account for.
    const corrective = first_tick + root.ticks_per_snapshot;
    try client.ack(corrective);
    try waitForAck(&loop.server, corrective);

    loop.server.lock();
    const model = loop.server.clients.items[0].held_tick.load(.acquire);
    loop.server.unlock();
    try std.testing.expectEqual(corrective, model);

    // The three deltas the model carried itself through are still queued; read
    // them, so what follows is unambiguously the response to the correction.
    i = 0;
    while (i < 3) : (i += 1) {
        const d = try client.expectFrame(&got, wire.msg.s2c_snapshot_delta, 4);
        const payload = d[wire.header_size..];
        try std.testing.expectEqual(
            first_tick + @as(u32, @intCast(i)) * root.ticks_per_snapshot,
            wire.readLe(u32, payload, 4),
        );
    }

    // And the next response is usable: a delta diffed against the tick the
    // client just named, which is the tick it holds, so it applies. Left
    // uncorrected, the model would have diffed against `held` instead.
    loop.server.step();
    loop.server.step();
    loop.server.step();
    const d = try client.expectFrame(&got, wire.msg.s2c_snapshot_delta, 4);
    const payload = d[wire.header_size..];
    try std.testing.expectEqual(corrective, wire.readLe(u32, payload, 4));
    try std.testing.expectEqual(held + root.ticks_per_snapshot, wire.readLe(u32, payload, 0));
}

test "a corrective acknowledgement the ring has lost still recovers" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var server = Server.init(std.Io.failing, gpa, &arena);

    const p = server.sim.spawnPlayer(0).?;
    p.pos = .{ 0.0, 0.0 };
    _ = server.sim.enemies.spawn(.circle_t1, .{ 5.0, 0.0 }).?;

    var conn = ClientConn{ .player_id = 0 };

    // The client acknowledges tick 3 and the model seeds from it.
    server.sim.tick = 3;
    server.snapshots.store(server.sim.snapshotView());
    conn.noteAck(3);
    try std.testing.expectEqual(@as(u32, 3), conn.held_tick.load(.acquire));

    // The server then carries the model forward onto each snapshot it sends,
    // the way a broadcast does, for long enough that the tick the client really
    // holds has fallen out of the 32-snapshot ring.
    var tick: u32 = 3;
    var i: usize = 0;
    while (i < delta.ring_size + 2) : (i += 1) {
        tick += root.ticks_per_snapshot;
        server.sim.tick = tick;
        server.snapshots.store(server.sim.snapshotView());
        const frame = try server.snapshotFrame(&conn);
        frame.release(gpa);
    }
    const ahead = conn.held_tick.load(.acquire);
    try std.testing.expect(ahead > 3 + root.ticks_per_snapshot);

    // The first corrective ack: different from the previous ack, behind the
    // model, and naming a tick the ring no longer holds. The model still
    // corrects — the ack is the truth about what the client holds, and holding
    // the model where it was would leave it diffing against a tick the client
    // has refused for as long as it takes the client to insist again.
    conn.noteAck(3 + root.ticks_per_snapshot);
    try std.testing.expectEqual(
        @as(u32, 3 + root.ticks_per_snapshot),
        conn.held_tick.load(.acquire),
    );

    // What follows is a full snapshot, baseline 0: there is no state to diff
    // against, so the client is handed one outright rather than a delta against
    // the model the correction just abandoned.
    tick += root.ticks_per_snapshot;
    server.sim.tick = tick;
    server.snapshots.store(server.sim.snapshotView());
    const full = try server.snapshotFrame(&conn);
    defer full.release(gpa);
    const header = wire.decodeFrameHeader(full.bytes).?;
    try std.testing.expectEqual(wire.msg.s2c_snapshot_full, header.msg_type);
    try std.testing.expectEqual(@as(u32, 0), wire.readLe(u32, full.bytes[wire.header_size..], 4));

    // And that is a recovery rather than a wedge: acknowledging the full
    // snapshot re-seeds the model, and the delta after it names the tick.
    try std.testing.expectEqual(@as(u32, 0), conn.held_tick.load(.acquire));
    conn.noteAck(tick);
    try std.testing.expectEqual(tick, conn.held_tick.load(.acquire));

    server.sim.tick = tick + root.ticks_per_snapshot;
    server.snapshots.store(server.sim.snapshotView());
    const d = try server.snapshotFrame(&conn);
    defer d.release(gpa);
    try std.testing.expectEqual(
        wire.msg.s2c_snapshot_delta,
        wire.decodeFrameHeader(d.bytes).?.msg_type,
    );
    try std.testing.expectEqual(tick, wire.readLe(u32, d.bytes[wire.header_size..], 4));
}

test "a restart takes the held state back to nothing" {
    const gpa = std.testing.allocator;
    const loop = try Loopback.start(gpa);
    defer loop.stop(gpa);

    var client: TestClient = .{};
    try client.init(loop, gpa);
    defer client.close();

    try client.hello("tester", 0x1234);
    try waitForClients(&loop.server, 1);
    try waitForIncoming(&loop.server, 1);
    loop.server.step();

    var got: [4096]u8 = undefined;
    _ = try client.expectFrame(&got, wire.msg.s2c_welcome, 4);
    _ = try client.readFrame(&got); // immediate full snapshot
    _ = try client.readFrame(&got); // loadout

    loop.server.step();
    loop.server.step();
    const first = try client.expectFrame(&got, wire.msg.s2c_snapshot_full, 4);
    const first_tick = wire.readLe(u32, first[wire.header_size..], 0);
    try client.ack(first_tick);
    try waitForAck(&loop.server, first_tick);

    // The run restarts: the server's tick goes back to zero, so a held tick from
    // the dead run names nothing the client has, and the client must be given a
    // full snapshot rather than a delta against it. The new run reaches the same
    // tick the client had acknowledged, which is exactly the case a model that
    // was only clamped by the tick going backwards would get wrong.
    try client.restart();
    try waitForIncoming(&loop.server, 1);
    loop.server.step();
    loop.server.step();
    loop.server.step();

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const frame = try client.readFrame(&got);
        const header = wire.decodeFrameHeader(frame).?;
        if (header.msg_type == wire.msg.s2c_snapshot_delta) return error.DeltaAfterRestart;
        if (header.msg_type == wire.msg.s2c_snapshot_full) {
            try std.testing.expectEqual(@as(u32, 0), wire.readLe(u32, frame[wire.header_size..], 4));
            return;
        }
    }
    return error.FrameNeverArrived;
}
