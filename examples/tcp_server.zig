const std = @import("std");
const zs = @import("zSockets");

const Allocator = std.mem.Allocator;

fn onWakeup(_: Allocator, _: *zs.Loop) !void {} // stub

fn onPre(_: Allocator, _: *zs.Loop) !void {} // stub

fn onPost(_: Allocator, _: *zs.Loop) !void {} // stub

fn onHttpSocketWritable(_: Allocator, s: *zs.Socket) !*zs.Socket {
    return s;
}

fn onHttpSocketClose(_: Allocator, s: *zs.Socket, _: i32, _: ?*anyopaque) !*zs.Socket {
    std.log.info("Client disconnected\n", .{});
    return s;
}

fn onHttpSocketEnd(allocator: Allocator, s: *zs.Socket) !*zs.Socket {
    try s.shutdown(); // HTTP doesn't support half-closed sockets
    return s.close(allocator, 0, null);
}

fn onHttpSocketData(_: Allocator, s: *zs.Socket, _: []u8) !*zs.Socket {
    _ = try s.write("Hello short message!", false);
    return s;
}

fn onHttpSocketOpen(_: Allocator, s: *zs.Socket, _: bool, _: []u8) !*zs.Socket {
    std.log.info("Client connected\n", .{});
    return s;
}

fn onHttpSocketTimeout(_: Allocator, s: *zs.Socket) !*zs.Socket {
    return s;
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // create event loop
    const loop = try zs.Loop.init(allocator, null, null, &onWakeup, &onPre, &onPost);
    defer loop.deinit(allocator);

    const http_context = try zs.Context.init(allocator, null, loop);
    defer http_context.deinit(allocator);

    http_context.setOnOpen(&onHttpSocketOpen);
    http_context.setOnData(&onHttpSocketData);
    http_context.setOnWritable(&onHttpSocketWritable);
    http_context.setOnClose(&onHttpSocketClose);
    http_context.setOnTimeout(&onHttpSocketTimeout);
    http_context.setOnEnd(&onHttpSocketEnd);

    _ = try http_context.listen(allocator, null, null, 3000, 0);

    std.log.info("Listening on port 3000...\n", .{});
    try loop.run(allocator);
}
