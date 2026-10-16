const std = @import("std");
const root = @import("root.zig");
const sim = @import("sim.zig");
const server = @import("server.zig");

const usage =
    \\Usage: shaped-haven-server [--port <n>]
    \\
    \\  --port <n>  TCP port to listen on (default {d})
    \\
;

pub fn main(init: std.process.Init) !void {
    var port = root.default_port;

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

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    var srv = server.Server.init(threaded.io(), init.gpa, &arena);
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
