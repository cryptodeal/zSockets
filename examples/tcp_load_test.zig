const argsParser = @import("args");
const std = @import("std");
const zs = @import("zSockets");

const ssl = false;

const Options = struct {
    // This declares long options for double hyphen
    host: [:0]const u8 = "127.0.0.1",
    port: u32 = 3000,
    connections: u32 = 2000,
};

const request: []const u8 = "Hello there!";
var host: [:0]const u8 = undefined;
var port: u32 = undefined;
var connections: usize = undefined;

var responses: usize = undefined;

fn onWakeup(_: std.mem.Allocator, _: *zs.Loop) !void {
    // call `zs.loop.timerSweep` to expose bugs
    // try zs.loop.internalTimerSweep(allocator, loop);
}

fn onPre(_: std.mem.Allocator, _: *zs.Loop) !void {}

fn onPost(_: std.mem.Allocator, _: *zs.Loop) !void {}

fn onHttpSocketWritable(_: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    return s;
}

fn onHttpSocketClose(_: std.mem.Allocator, s: *zs.Socket, _: i32, _: ?*anyopaque) !*zs.Socket {
    return s;
}

fn onHttpSocketEnd(allocator: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    return s.close(allocator, ssl, 0, null);
}

fn onHttpSocketData(_: std.mem.Allocator, s: *zs.Socket, _: []u8) !*zs.Socket {
    _ = s.write(ssl, request, false);
    responses += 1;
    return s;
}

fn onHttpSocketOpen(allocator: std.mem.Allocator, s: *zs.Socket, _: bool, _: []u8) !*zs.Socket {
    _ = s.write(ssl, request, false);
    connections -= 1;
    if (connections != 0) {
        _ = try s.context.connect(allocator, ssl, host, port, null, 0, null);
    } else {
        std.debug.print("Running benchmark now...\n", .{});
        s.setTimeout(ssl, zs.constants.timeout_granularity);
        s.setLongTimeout(ssl, 1);
    }
    return s;
}

fn onHttpSocketLongTimeout(_: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    std.debug.print("--- Minute mark ---\n", .{});
    s.setLongTimeout(ssl, 1);
    return s;
}

fn onHttpSocketTimeout(_: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    std.debug.print("Req/sec: {d}\n", .{@as(f64, @floatFromInt(responses)) / zs.constants.timeout_granularity});
    responses = 0;
    s.setTimeout(ssl, zs.constants.timeout_granularity);
    return s;
}

fn onHttpSocketConnectError(_: std.mem.Allocator, s: *zs.Socket, _: i32) !*zs.Socket {
    std.debug.print("Cannot connect to server\n", .{});
    return s;
}

pub fn main(init: std.process.Init) !void {
    const args = try argsParser.parseForCurrentProcess(Options, init, .print);
    defer args.deinit();

    // var gpa = std.heap.DebugAllocator(.{}){};
    // defer std.debug.assert(gpa.deinit() == .ok);
    // const allocator = gpa.allocator();

    const allocator = std.heap.smp_allocator;

    host = args.options.host;
    port = args.options.port;
    connections = args.options.connections;

    const loop = try zs.Loop.init(allocator, null, &onWakeup, &onPre, &onPost, null);
    defer loop.deinit(allocator);

    // TODO: enable SSL and pass relevant options
    const options: zs.SocketContextOptions = .{};
    const http_context = try zs.SocketContext.init(allocator, ssl, loop, options, null);
    // TODO: implement `SocketContext.deinit`
    defer http_context.deinit(allocator);

    http_context.setOnOpen(ssl, &onHttpSocketOpen);
    http_context.setOnData(ssl, &onHttpSocketData);
    http_context.setOnWritable(ssl, &onHttpSocketWritable);
    http_context.setOnClose(ssl, &onHttpSocketClose);
    http_context.setOnTimeout(ssl, &onHttpSocketTimeout);
    http_context.setOnLongTimeout(ssl, &onHttpSocketLongTimeout);
    http_context.setOnEnd(ssl, &onHttpSocketEnd);
    http_context.setOnConnectError(ssl, &onHttpSocketConnectError);

    if (http_context.connect(allocator, ssl, host, port, null, 0, null)) |_| {} else |err| {
        std.debug.print("Cannot connect to server\n", .{});
        return err;
    }

    try loop.run(allocator);
}
