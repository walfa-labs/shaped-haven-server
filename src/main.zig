const std = @import("std");
const root = @import("root.zig");
const sim = @import("sim.zig");
const server = @import("server.zig");
const loadout = @import("loadout.zig");

const usage =
    \\Usage: shaped-haven-server [--port <n>] [--stress-enemies <n>] [--stress-projectiles <n>]
    \\                      [--debug-loadout <spec>]
    \\
    \\  --port <n>                 TCP port to listen on (default {d})
    \\  --stress-enemies <n>       Hold n enemies live around the players, instead
    \\                             of waiting for the spawn curve to reach them.
    \\                             A measurement tool: the natural curve does not
    \\                             reach 1000 enemies for about twelve minutes.
    \\  --stress-projectiles <n>   Hold n gun projectiles live as well.
    \\  --debug-loadout <spec>     TEST AFFORDANCE, NOT GAMEPLAY. Start every run
    \\                             with the given loadout instead of the single
    \\                             starting weapon, on every join and every
    \\                             restart. <spec> is comma-separated name=level
    \\                             pairs, e.g. "sword=8,clockwork_gear=5" (which
    \\                             arms the Vorpal Blender), or item ids from
    \\                             PROTOCOL.md, e.g. "0=8,18=5". An empty spec
    \\                             starts a run with the normal loadout.
    \\
;

pub fn main(init: std.process.Init) !void {
    var port = root.default_port;
    var stress: ?sim.StressLoad = null;
    var loadout_spec: ?[]const u8 = null;

    var args = try std.process.Args.iterateAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next(); // the executable path

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const value = args.next();
            port = std.fmt.parseUnsigned(u16, value orelse "", 10) catch {
                std.debug.print("error: invalid port '{s}'\n", .{value orelse ""});
                return error.InvalidArguments;
            };
        } else if (std.mem.eql(u8, arg, "--debug-loadout")) {
            loadout_spec = args.next() orelse {
                std.debug.print("error: --debug-loadout needs a spec, e.g. --debug-loadout \"sword=8,clockwork_gear=5\"\n", .{});
                return error.InvalidArguments;
            };
        } else if (std.mem.eql(u8, arg, "--stress-enemies") or
            std.mem.eql(u8, arg, "--stress-projectiles"))
        {
            const is_enemies = std.mem.eql(u8, arg, "--stress-enemies");
            const value = args.next();
            const n = std.fmt.parseUnsigned(usize, value orelse "", 10) catch {
                std.debug.print("error: invalid count for {s}: '{s}'\n", .{ arg, value orelse "" });
                return error.InvalidArguments;
            };
            var load = stress orelse sim.StressLoad{ .enemies = 0, .projectiles = 0 };
            if (is_enemies) load.enemies = n else load.projectiles = n;
            stress = load;
        } else {
            std.debug.print(usage, .{root.default_port});
            return error.InvalidArguments;
        }
    }

    var debug_loadout: ?loadout.Loadout = null;
    if (loadout_spec) |spec| {
        debug_loadout = loadout.parse(spec) catch {
            std.debug.print(
                "error: invalid --debug-loadout spec '{s}'\n" ++
                    "  expected comma-separated name=level pairs, e.g. --debug-loadout \"sword=8,clockwork_gear=5\"\n",
                .{spec},
            );
            return error.InvalidArguments;
        };
    }

    std.debug.print(
        "shaped-haven-server — protocol v{d}\n" ++
            "  tick rate:     {d} Hz\n" ++
            "  snapshots:     {d} Hz\n" ++
            "  arena:         {d} x {d} units\n" ++
            "  player speed:  {d} units/s\n" ++
            "  listening on   127.0.0.1:{d}\n",
        .{
            root.protocol_version,
            root.tick_hz,
            root.snapshot_hz,
            @as(i32, @intFromFloat(root.arena_half_size * 2)),
            @as(i32, @intFromFloat(root.arena_half_size * 2)),
            @as(i32, @intFromFloat(root.move_speed)),
            port,
        },
    );
    if (stress) |load| {
        std.debug.print(
            "  STRESS LOAD:   holding {d} enemies and {d} projectiles live\n",
            .{ load.enemies, load.projectiles },
        );
    }
    if (loadout_spec) |spec| {
        std.debug.print(
            "  DEBUG LOADOUT: {s}   (TEST AFFORDANCE — NOT GAMEPLAY)\n",
            .{spec},
        );
    }

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    var srv = server.Server.init(threaded.io(), init.gpa, &arena);
    srv.sim.stress = stress;
    srv.sim.loadout = debug_loadout;
    try srv.listen(port);
    defer srv.shutdown();

    srv.run();
    std.debug.print("[server] shut down\n", .{});
}

test "server constants match the design document" {
    try std.testing.expectEqual(@as(u32, 60), root.tick_hz);
    try std.testing.expectEqual(@as(u32, 20), root.snapshot_hz);
    try std.testing.expectEqual(@as(u16, 7777), root.default_port);
}
