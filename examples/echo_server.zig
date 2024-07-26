const std = @import("std");
const zs = @import("zSockets").Network(false, .{ .socket = EchoSocket });

const Allocator = std.mem.Allocator;

const EchoSocket = struct {
    backpressure: []u8,
};

const EchoCtx = struct {};

// Loop wakeup handler
fn onWakeup(_: Allocator, _: *zs.Loop) !void {} // stub
// Loop pre-iteration handler
fn onPre(_: Allocator, _: *zs.Loop) !void {} // stub
// Loop post-iteration handler
fn onPost(_: Allocator, _: *zs.Loop) !void {} // stub

// Socket writable handler
fn onEchoSocketWritable(allocator: Allocator, s: *zs.Socket) !*zs.Socket {
    const es: *EchoSocket = @ptrCast(@alignCast(s.getExt()));
    const written = try s.write(es.backpressure, false);
    if (written != es.backpressure.len) {
        const new_len: usize = @intCast(@as(isize, @intCast(es.backpressure.len)) - written);
        const new_buffer = try allocator.alloc(u8, new_len);
        @memcpy(new_buffer, es.backpressure[0..new_len]);
        allocator.free(es.backpressure);
        es.backpressure = new_buffer;
    } else {
        allocator.free(es.backpressure);
        es.backpressure = &[_]u8{};
    }
    s.setTimeout(30);
    return s;
}

// Socket close handler
fn onEchoSocketClose(allocator: Allocator, s: *zs.Socket, _: i32, _: ?*anyopaque) !*zs.Socket {
    const es: *EchoSocket = @ptrCast(@alignCast(s.getExt()));
    std.log.info("Client disconnected\n", .{});
    allocator.free(es.backpressure);
    return s;
}

// Socket half-closed handler
fn onEchoSocketEnd(allocator: Allocator, s: *zs.Socket) !*zs.Socket {
    try s.shutdown();
    return s.close(allocator, 0, null);
}

// Socket data handler
fn onEchoSocketData(allocator: Allocator, s: *zs.Socket, data: []u8) !*zs.Socket {
    const es: *EchoSocket = @ptrCast(@alignCast(s.getExt()));
    // print received data
    std.log.info("Client sent: {s}\n", .{data});

    // send back or buffer it
    const written = try s.write(data, false);
    if (written != @as(isize, @intCast(data.len))) {
        const new_len: usize = @intCast(@as(isize, @intCast(es.backpressure.len + data.len)) - written);
        const new_buffer = try allocator.alloc(u8, new_len);

        @memcpy(new_buffer[0..es.backpressure.len], es.backpressure);
        @memcpy(new_buffer[es.backpressure.len..], data[@intCast(written)..][0..@intCast(@as(isize, @intCast(data.len)) - written)]);
        allocator.free(es.backpressure);
        es.backpressure = new_buffer;
    }
    s.setTimeout(30);
    return s;
}

// Socket open handler
fn onEchoSocketOpen(_: Allocator, s: *zs.Socket, _: bool, _: []u8) !*zs.Socket {
    const es: *EchoSocket = @ptrCast(@alignCast(s.getExt()));
    es.backpressure = &[_]u8{};
    s.setTimeout(30);
    std.log.info("Client connected\n", .{});
    return s;
}

// Socket timeout handler
fn onEchoSocketTimeout(allocator: Allocator, s: *zs.Socket) !*zs.Socket {
    std.log.info("Client timed out\n", .{});
    return s.close(allocator, 0, null);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const loop = try zs.Loop.init(allocator, null, &onWakeup, &onPre, &onPost);
    // TODO(cryptodeal): implement `Loop.deinit()` method

    const echo_context = try zs.SocketCtx.init(allocator, loop);
    // TODO(cryptodeal): implement `SocketCtx.deinit()` method

    // register event handlers
    echo_context.setOnOpen(&onEchoSocketOpen);
    echo_context.setOnData(&onEchoSocketData);
    echo_context.setOnWritable(&onEchoSocketWritable);
    echo_context.setOnClose(&onEchoSocketClose);
    echo_context.setOnTimeout(&onEchoSocketTimeout);
    echo_context.setOnEnd(&onEchoSocketEnd);

    _ = try echo_context.listen(allocator, null, 3000, 0);
    // TODO(cryptodeal): implement `ListenSocket.deinit()` method
    std.debug.print("Listening on port 3000\n", .{});
    try loop.run(allocator);
}
