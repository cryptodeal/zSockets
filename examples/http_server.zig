const std = @import("std");
const zs = @import("zSockets");

const Allocator = std.mem.Allocator;

const HttpSocket = extern struct {
    offset: usize, // how much of the request has been streamed
};

const HttpCtx = extern struct {
    response: [*]u8,
    len: usize,
};

fn onWakeup(_: Allocator, _: *zs.Loop) !void {} // stub

fn onPre(_: Allocator, _: *zs.Loop) !void {} // stub

fn onPost(_: Allocator, _: *zs.Loop) !void {} // stub

fn onHttpSocketWritable(_: Allocator, s: *zs.Socket) !*zs.Socket {
    const http_socket = s.ext(HttpSocket).?;
    const http_context = s.ctx().ext(HttpCtx).?;
    // stream what remains of the response
    http_socket.offset += @intCast(try s.write(http_context.response[http_socket.offset..http_context.len], false));
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
    const http_socket = s.ext(HttpSocket).?;
    const http_context = s.ctx().ext(HttpCtx).?;
    // treat all data events as a request
    http_socket.offset = @intCast(try s.write(http_context.response[0..http_context.len], false));
    // reset idle timer
    s.setTimeout(30);
    return s;
}

fn onHttpSocketOpen(_: Allocator, s: *zs.Socket, _: bool, _: []u8) !*zs.Socket {
    const http_socket = s.ext(HttpSocket).?;
    http_socket.offset = 0; // reset offset
    s.setTimeout(30); // Timeout idle HTTP connections
    std.log.info("Client connected\n", .{});
    return s;
}

fn onHttpSocketTimeout(allocator: Allocator, s: *zs.Socket) !*zs.Socket {
    return s.close(allocator, 0, null);
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // create event loop
    const loop = try zs.Loop.init(allocator, null, null, &onWakeup, &onPre, &onPost);
    defer loop.deinit(allocator);

    const http_context = try zs.Context.init(allocator, HttpCtx, loop);
    defer http_context.deinit(allocator);

    // Generate the shared response
    const body = "<html><body><h1>Why hello there!</h1></body></html>";
    const http_context_ext = http_context.ext(HttpCtx).?;
    var buffer = try allocator.alloc(u8, 128 + body.len);
    defer allocator.free(buffer);
    buffer = try std.fmt.bufPrint(buffer, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ @as(c_long, @intCast(body.len)), body });
    http_context_ext.response = buffer.ptr;
    http_context_ext.len = buffer.len;

    http_context.setOnOpen(&onHttpSocketOpen);
    http_context.setOnData(&onHttpSocketData);
    http_context.setOnWritable(&onHttpSocketWritable);
    http_context.setOnClose(&onHttpSocketClose);
    http_context.setOnTimeout(&onHttpSocketTimeout);
    http_context.setOnEnd(&onHttpSocketEnd);

    _ = try http_context.listen(allocator, HttpSocket, null, 3000, 0);

    std.log.info("Listening on port 3000...\n", .{});
    try loop.run(allocator);
}
