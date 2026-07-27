const std = @import("std");
const zs = @import("zSockets");

const ssl = true;

const EchoSocket = struct {
    backpressure: []u8,
};

const EchoContext = struct {};

fn onWakeup(_: std.mem.Allocator, _: *zs.Loop) !void {}

fn onPre(_: std.mem.Allocator, _: *zs.Loop) !void {}

fn onPost(_: std.mem.Allocator, _: *zs.Loop) !void {}

fn onEchoSocketWritable(allocator: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    const es = s.getExt(EchoSocket).?;
    const written = s.write(ssl, es.backpressure, false);
    if (written != es.backpressure.len) {
        const new_buffer = try allocator.alloc(u8, es.backpressure.len - written);
        @memcpy(new_buffer, es.backpressure[written .. written + (es.backpressure.len - written)]);
        allocator.free(es.backpressure);
        es.backpressure = new_buffer;
    } else {
        allocator.free(es.backpressure);
        es.backpressure = &[_]u8{};
    }
    s.setTimeout(ssl, 30);
    return s;
}

fn onEchoSocketClose(allocator: std.mem.Allocator, s: *zs.Socket, _: i32, _: ?*anyopaque) !*zs.Socket {
    const es = s.getExt(EchoSocket).?;
    std.debug.print("Client disconnected\n", .{});
    allocator.free(es.backpressure);
    return s;
}

fn onEchoSocketEnd(allocator: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    s.shutdown(ssl);
    return s.close(allocator, ssl, 0, null);
}

fn onEchoSocketData(allocator: std.mem.Allocator, s: *zs.Socket, data: []u8) !*zs.Socket {
    const es = s.getExt(EchoSocket).?;
    std.debug.print("Client sent: {s}", .{data});
    const written = s.write(ssl, data, false);
    if (written != data.len) {
        const new_buffer = try allocator.alloc(u8, es.backpressure.len + data.len - written);
        @memcpy(new_buffer[0..es.backpressure.len], es.backpressure);
        @memcpy(new_buffer[es.backpressure.len .. es.backpressure.len + (data.len - written)], data[written..]);
        allocator.free(es.backpressure);
        es.backpressure = new_buffer;
    }
    s.setTimeout(ssl, 30);
    return s;
}

fn onEchoSocketOpen(_: std.mem.Allocator, s: *zs.Socket, _: bool, _: []u8) !*zs.Socket {
    const es = s.getExt(EchoSocket).?;
    es.backpressure = &[_]u8{};
    s.setTimeout(ssl, 30);
    std.debug.print("Client connected\n", .{});
    return s;
}

fn onEchoSocketTimeout(allocator: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    std.debug.print("Client was idle for too long\n", .{});
    return s.close(allocator, ssl, 0, null);
}

pub fn main(_: std.process.Init) !void {
    // var gpa = std.heap.DebugAllocator(.{}){};
    // defer std.debug.assert(gpa.deinit() == .ok);
    // const allocator = gpa.allocator();

    const allocator = std.heap.smp_allocator;

    const loop = try zs.Loop.init(allocator, null, &onWakeup, &onPre, &onPost, null);
    defer loop.deinit(allocator);

    // TODO: enable SSL and pass relevant options
    const options: zs.SocketContextOptions = .{
        .key_file_name = "/Users/cryptodeal/zSockets/misc/valid_server_key.pem",
        .cert_file_name = "/Users/cryptodeal/zSockets/misc/valid_server_crt.pem",
        .passphrase = "1234",
    };
    const echo_context = try zs.SocketContext.init(allocator, ssl, loop, options, EchoContext);
    // TODO: implement `SocketContext.deinit`
    defer echo_context.deinit(allocator);

    echo_context.setOnOpen(ssl, &onEchoSocketOpen);
    echo_context.setOnData(ssl, &onEchoSocketData);
    echo_context.setOnWritable(ssl, &onEchoSocketWritable);
    echo_context.setOnClose(ssl, &onEchoSocketClose);
    echo_context.setOnTimeout(ssl, &onEchoSocketTimeout);
    echo_context.setOnEnd(ssl, &onEchoSocketEnd);

    if (echo_context.listen(allocator, ssl, null, 3000, 0, EchoSocket)) |_| {
        std.debug.print("Listening on port 3000...\n", .{});
        try loop.run(allocator);
    } else |_| {
        std.debug.print("Failed to listen!\n", .{});
    }
}
