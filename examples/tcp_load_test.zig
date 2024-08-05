const std = @import("std");
const zs = @import("zSockets");

const Allocator = std.mem.Allocator;

const request = "Hello there!";
var host: ?[:0]u8 = null;
var port: u64 = undefined;
var connections: u64 = undefined;
var responses: u64 = undefined;

fn onWakeup(_: Allocator, _: *zs.Loop) !void {} // stub

fn onPre(_: Allocator, _: *zs.Loop) !void {} // stub

fn onPost(_: Allocator, _: *zs.Loop) !void {} // stub

fn onHttpSocketWritable(_: Allocator, s: *zs.Socket) !*zs.Socket {
    return s;
}

fn onHttpSocketClose(_: Allocator, s: *zs.Socket, _: i32, _: ?*anyopaque) !*zs.Socket {
    return s;
}

fn onHttpSocketEnd(allocator: Allocator, s: *zs.Socket) !*zs.Socket {
    return s.close(allocator, 0, null);
}

fn onHttpSocketData(_: Allocator, s: *zs.Socket, _: []u8) !*zs.Socket {
    _ = try s.write(request, false);
    responses += 1;
    return s;
}

fn onHttpSocketOpen(allocator: Allocator, s: *zs.Socket, _: bool, _: []u8) !*zs.Socket {
    _ = try s.write(request, false);
    connections -= 1;
    if (connections != 0) {
        _ = try s.ctx().connect(allocator, null, host, port, null, 0);
    } else {
        std.log.info("Running benchmark now...\n", .{});

        s.setTimeout(zs.TIMEOUT_GRANULARITY);
        s.setLongTimeout(1);
    }
    return s;
}

fn onHttpSocketLongTimeout(_: Allocator, s: *zs.Socket) !*zs.Socket {
    std.log.info("--- Minute mark ---\n", .{});
    s.setLongTimeout(1);
    return s;
}

fn onHttpSocketTimeout(_: Allocator, s: *zs.Socket) !*zs.Socket {
    std.log.info("Req/sec: {d}\n", .{@as(f32, @floatFromInt(responses)) / zs.TIMEOUT_GRANULARITY});
    responses = 0;
    s.setTimeout(zs.TIMEOUT_GRANULARITY);
    return s;
}

fn onHttpSocketConnectErr(_: Allocator, s: *zs.Socket, _: i32) !*zs.Socket {
    std.log.info("Cannot connect to server\n", .{});
    return s;
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 4) {
        std.log.err("Usage: connections host port\n", .{});
        return error.InvalidArgs;
    }

    port = try std.fmt.parseInt(u64, args[3], 10);
    host = try allocator.dupeZ(u8, args[2]);
    defer if (host) |h| allocator.free(h);
    connections = try std.fmt.parseInt(u64, args[1], 10);

    const loop = try zs.Loop.init(allocator, null, null, &onWakeup, &onPre, &onPost);
    defer loop.deinit(allocator);

    const http_context = try zs.Context.init(allocator, null, loop);
    defer http_context.deinit(allocator);

    http_context.setOnOpen(&onHttpSocketOpen);
    http_context.setOnData(&onHttpSocketData);
    http_context.setOnWritable(&onHttpSocketWritable);
    http_context.setOnClose(&onHttpSocketClose);
    http_context.setOnTimeout(&onHttpSocketTimeout);
    http_context.setOnLongTimeout(&onHttpSocketLongTimeout);
    http_context.setOnEnd(&onHttpSocketEnd);
    http_context.setOnConnectError(&onHttpSocketConnectErr);

    _ = try http_context.connect(allocator, null, host, port, null, 0);

    try loop.run(allocator);
}
