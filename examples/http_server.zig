const std = @import("std");
const zs = @import("zSockets");

const ssl = true;

const HttpSocket = struct {
    offset: usize,
};

const HttpContext = struct {
    response: []u8,
};

fn onWakeup(_: std.mem.Allocator, _: *zs.Loop) !void {}

fn onPre(_: std.mem.Allocator, _: *zs.Loop) !void {}

fn onPost(_: std.mem.Allocator, _: *zs.Loop) !void {}

fn onHttpSocketWritable(_: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    const http_socket = s.getExt(HttpSocket).?;
    const http_context = s.context.getExt(HttpContext).?;
    http_socket.offset += s.write(ssl, http_context.response[http_socket.offset..], false);
    return s;
}

fn onHttpSocketClose(_: std.mem.Allocator, s: *zs.Socket, _: i32, _: ?*anyopaque) !*zs.Socket {
    std.debug.print("Client disconnected\n", .{});
    return s;
}

fn onHttpSocketEnd(allocator: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    s.shutdown(ssl);
    return s.close(allocator, ssl, 0, null);
}

fn onHttpSocketData(_: std.mem.Allocator, s: *zs.Socket, _: []u8) !*zs.Socket {
    const http_socket = s.getExt(HttpSocket).?;
    const http_context = s.context.getExt(HttpContext).?;
    http_socket.offset = s.write(ssl, http_context.response, false);
    s.setTimeout(ssl, 30);
    return s;
}

fn onHttpSocketOpen(_: std.mem.Allocator, s: *zs.Socket, _: bool, _: []u8) !*zs.Socket {
    const http_socket = s.getExt(HttpSocket).?;
    http_socket.offset = 0;
    s.setTimeout(ssl, 30);
    std.debug.print("Client connected\n", .{});
    return s;
}

fn onHttpSocketTimeout(allocator: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
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
    const http_context = zs.SocketContext.init(allocator, false, loop, options, HttpContext) catch |err| {
        std.debug.print("Could not load SSL cert/key\n", .{});
        return err;
    };
    // TODO: implement `SocketContext.deinit`
    defer http_context.deinit(allocator);

    const body = "<html><body><h1>Why hello there!</h1></body></html>";

    const http_context_ext = http_context.getExt(HttpContext).?;
    var http_context_buffer: [128 + body.len]u8 = undefined;
    http_context_ext.response = try std.fmt.bufPrint(&http_context_buffer, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });

    http_context.setOnOpen(false, &onHttpSocketOpen);
    http_context.setOnData(false, &onHttpSocketData);
    http_context.setOnWritable(false, &onHttpSocketWritable);
    http_context.setOnClose(false, &onHttpSocketClose);
    http_context.setOnTimeout(false, &onHttpSocketTimeout);
    http_context.setOnEnd(false, &onHttpSocketEnd);

    if (http_context.listen(allocator, false, null, 3000, 0, HttpSocket)) |_| {
        std.debug.print("Listening on port 3000...\n", .{});
        try loop.run(allocator);
    } else |_| {
        std.debug.print("Failed to listen!\n", .{});
    }
}
