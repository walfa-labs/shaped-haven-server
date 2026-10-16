const std = @import("std");
const root = @import("root.zig");
const sim = @import("sim.zig");
const server = @import("server.zig");

const usage =
    \\Usage: shaped-haven-server [--port <n>] [--stress-enemies <n>] [--stress-projectiles <n>]
    \\
    \\  --port <n>                 TCP port to listen on (default {d})
    \\  --stress-enemies <n>       Hold n enemies live around the players, instead
    \\                             of waiting for the spawn curve to reach them.
    \\                             A measurement tool: the natural curve does not
    \\                             reach 1000 enemies for about twelve minutes.
    \\  --stress-projectiles <n>   Hold n gun projectiles live as well.
    \\
;

pub fn main(init: std.process.Init) !void {
    var port = root.default_port;
    var stress: ?sim.StressLoad = null;

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

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    var srv = server.Server.init(threaded.io(), init.gpa, &arena);
    srv.sim.stress = stress;
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
