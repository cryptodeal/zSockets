const std = @import("std");
const zs = @import("zSockets");

const ssl = true;

var port: u32 = undefined;
var opened_connections: usize = undefined;
var closed_connections: usize = undefined;
var operations_done: usize = undefined;

var server_context: *zs.SocketContext = undefined;
var client_context: *zs.SocketContext = undefined;

var listen_socket: ?*zs.ListenSocket = null;

const client_msg = "Hello from client";
const server_msg = "Hello from server";

var client_received_data: bool = undefined;
var server_received_data: bool = undefined;

const SocketCtx = struct {
    backpressure: []u8,
};

fn onWakeup(allocator: std.mem.Allocator, loop: *zs.Loop) !void {
    try zs.loop.internalTimerSweep(allocator, loop);
}

fn onPre(_: std.mem.Allocator, _: *zs.Loop) !void {}

fn onPost(_: std.mem.Allocator, _: *zs.Loop) !void {}

fn writeBuffered(allocator: std.mem.Allocator, ssl_: bool, s: *zs.Socket, data: []const u8) !usize {
    const ctx = s.getExt(SocketCtx).?;
    const written = s.write(ssl_, data, false);
    if (written != data.len) {
        const new_buffer = try allocator.alloc(u8, ctx.backpressure.len + data.len - written);
        @memcpy(new_buffer[0..ctx.backpressure.len], ctx.backpressure);
        @memcpy(new_buffer[ctx.backpressure.len..], data[written..]);
        allocator.free(ctx.backpressure);
        ctx.backpressure = new_buffer;
    }
    return written;
}

fn writeBackpressure(allocator: std.mem.Allocator, ssl_: bool, s: *zs.Socket) !void {
    const ctx = s.getExt(SocketCtx).?;
    const written = s.write(ssl_, ctx.backpressure, false);
    if (written != ctx.backpressure.len) {
        const new_buffer = try allocator.alloc(u8, ctx.backpressure.len - written);
        @memcpy(new_buffer, ctx.backpressure[0 .. ctx.backpressure.len - written]);
        allocator.free(ctx.backpressure);
        ctx.backpressure = new_buffer;
    } else {
        allocator.free(ctx.backpressure);
        ctx.backpressure = &.{};
    }
}

fn onServerSocketWritable(allocator: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    std.debug.print("onServerSocketWritable\n", .{});
    try writeBackpressure(allocator, ssl, s);
    // Peer is not boring
    s.setTimeout(ssl, 30);
    return s;
}

fn onClientSocketWritable(allocator: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    std.debug.print("onClientSocketWritable\n", .{});
    try writeBackpressure(allocator, ssl, s);
    // Peer is not boring
    s.setTimeout(ssl, 30);
    return s;
}

fn onServerSocketClose(_: std.mem.Allocator, s: *zs.Socket, _: i32, _: ?*anyopaque) !*zs.Socket {
    std.debug.print("onServerSocketClose\n", .{});
    listen_socket.?.close(ssl);
    return s;
}

fn onClientSocketClose(_: std.mem.Allocator, s: *zs.Socket, _: i32, _: ?*anyopaque) !*zs.Socket {
    std.debug.print("onClientSocketClose\n", .{});
    return s;
}

fn onServerSocketEnd(allocator: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    return s.close(allocator, ssl, 0, null);
}

fn onClientSocketEnd(allocator: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    return s.close(allocator, ssl, 0, null);
}

fn onServerSocketData(allocator: std.mem.Allocator, s: *zs.Socket, data: []u8) !*zs.Socket {
    if (data.len == 0) {
        std.debug.print("ERROR: Got data event with no data\n", .{});
        std.process.exit(1);
    }
    std.debug.print("onServerSocketData: received '{s}'\n", .{data});
    server_received_data = true;
    _ = try writeBuffered(allocator, ssl, s, server_msg);
    return s;
}

fn onClientSocketData(allocator: std.mem.Allocator, s: *zs.Socket, data: []u8) !*zs.Socket {
    if (data.len == 0) {
        std.debug.print("ERROR: Got data event with no data\n", .{});
        std.process.exit(1);
    }
    std.debug.print("onClientSocketData: received '{s}'\n", .{data});
    client_received_data = true;
    return s.close(allocator, ssl, 0, null);
}

fn onServerSocketOpen(_: std.mem.Allocator, s: *zs.Socket, _: bool, _: []u8) !*zs.Socket {
    std.debug.print("onServerSocketOpen\n", .{});
    const ctx = s.getExt(SocketCtx).?;
    ctx.backpressure = &.{};
    s.setTimeout(ssl, 30);
    std.debug.print("Client connected\n", .{});
    return s;
}

fn onClientSocketOpen(allocator: std.mem.Allocator, s: *zs.Socket, _: bool, _: []u8) !*zs.Socket {
    std.debug.print("onClientSocketOpen\n", .{});
    const ctx = s.getExt(SocketCtx).?;
    ctx.backpressure = &.{};
    _ = try writeBuffered(allocator, ssl, s, client_msg);
    return s;
}

fn onClientSocketTimeout(_: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    return s;
}

fn onServerSocketTimeout(_: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    return s;
}

fn expectPeerVerify(allocator: std.mem.Allocator, test_name: []const u8, expect_data_exchanged: bool, server_options: zs.SocketContextOptions, client_options: zs.SocketContextOptions) !void {
    std.debug.print(
        "----------------------------------------\n[[ {s} ]]\n  server_key: {s}\n  server_crt: {s}\n  server_ca: {s}\n  client_crt: {s}\n  client_key: {s}\n  client_ca: {s}\n\n",
        .{
            test_name,
            server_options.key_file_name,
            server_options.cert_file_name,
            server_options.ca_file_name,
            client_options.key_file_name,
            client_options.cert_file_name,
            client_options.ca_file_name,
        },
    );

    server_received_data = false;
    client_received_data = false;

    const loop = try zs.Loop.init(allocator, null, &onWakeup, &onPre, &onPost, null);
    defer loop.deinit(allocator);

    server_context = try zs.SocketContext.init(allocator, ssl, loop, server_options, null);
    defer server_context.deinit(allocator);
    server_context.setOnOpen(ssl, &onServerSocketOpen);
    server_context.setOnData(ssl, &onServerSocketData);
    server_context.setOnWritable(ssl, &onServerSocketWritable);
    server_context.setOnClose(ssl, &onServerSocketClose);
    server_context.setOnTimeout(ssl, &onServerSocketTimeout);
    server_context.setOnEnd(ssl, &onServerSocketEnd);

    port = 3000;
    while (listen_socket == null) {
        listen_socket = blk: {
            const tmp_listen_socket = server_context.listen(allocator, ssl, "127.0.0.1", port, 0, SocketCtx) catch break :blk null;
            break :blk tmp_listen_socket;
        };
        if (listen_socket != null) break;
        port += 1;
    }
    std.debug.print("Server listening on 127.0.0.1:{d}\n", .{port});
    client_context = try zs.SocketContext.init(allocator, ssl, loop, client_options, null);
    defer client_context.deinit(allocator);
    client_context.setOnOpen(ssl, &onClientSocketOpen);
    client_context.setOnData(ssl, &onClientSocketData);
    client_context.setOnWritable(ssl, &onClientSocketWritable);
    client_context.setOnClose(ssl, &onClientSocketClose);
    client_context.setOnTimeout(ssl, &onClientSocketTimeout);
    client_context.setOnEnd(ssl, &onClientSocketEnd);

    _ = try client_context.connect(allocator, ssl, "127.0.0.1", port, null, 0, SocketCtx);
    try loop.run(allocator);
    listen_socket = null;

    const data_exchanged = server_received_data and client_received_data;
    if (!!expect_data_exchanged != !!data_exchanged) {
        std.log.err("\n~ ERROR: expected data_exchanged == {any}, got {any}\n\n", .{ expect_data_exchanged, data_exchanged });
        std.process.exit(1);
    }
    std.debug.print("[[ OK ]]\n\n", .{});
}

pub fn main(_: std.process.Init) !void {
    // var gpa = std.heap.DebugAllocator(.{}){};
    // defer std.debug.assert(gpa.deinit() == .ok);
    // const allocator = gpa.allocator();

    const allocator = std.heap.smp_allocator;

    // const allocator = std.heap.smp_allocator;
    try expectPeerVerify(allocator, "trusted client ca", true, .{
        .key_file_name = "/Users/cryptodeal/zSockets/misc/valid_server_key.pem",
        .cert_file_name = "/Users/cryptodeal/zSockets/misc/valid_server_crt.pem",
        .ca_file_name = "/Users/cryptodeal/zSockets/misc/valid_ca_crt.pem",
    }, .{
        .key_file_name = "/Users/cryptodeal/zSockets/misc/valid_client_key.pem",
        .cert_file_name = "/Users/cryptodeal/zSockets/misc/valid_client_crt.pem",
        .ca_file_name = "/Users/cryptodeal/zSockets/misc/valid_ca_crt.pem",
    });

    try expectPeerVerify(allocator, "untrusted client ca", false, .{
        .key_file_name = "/Users/cryptodeal/zSockets/misc/valid_server_key.pem",
        .cert_file_name = "/Users/cryptodeal/zSockets/misc/valid_server_crt.pem",
        .ca_file_name = "/Users/cryptodeal/zSockets/misc/valid_ca_crt.pem",
    }, .{
        .key_file_name = "/Users/cryptodeal/zSockets/misc/invalid_client_key.pem",
        .cert_file_name = "/Users/cryptodeal/zSockets/misc/invalid_client_crt.pem",
        .ca_file_name = "/Users/cryptodeal/zSockets/misc/valid_ca_crt.pem",
    });

    try expectPeerVerify(allocator, "trusted selfsigned client", true, .{
        .key_file_name = "/Users/cryptodeal/zSockets/misc/valid_server_key.pem",
        .cert_file_name = "/Users/cryptodeal/zSockets/misc/valid_server_crt.pem",
        .ca_file_name = "/Users/cryptodeal/zSockets/misc/selfsigned_client_crt.pem",
    }, .{
        .key_file_name = "/Users/cryptodeal/zSockets/misc/selfsigned_client_key.pem",
        .cert_file_name = "/Users/cryptodeal/zSockets/misc/selfsigned_client_crt.pem",
        .ca_file_name = "/Users/cryptodeal/zSockets/misc/valid_ca_crt.pem",
    });

    try expectPeerVerify(allocator, "untrusted selfsigned client", false, .{
        .key_file_name = "/Users/cryptodeal/zSockets/misc/valid_server_key.pem",
        .cert_file_name = "/Users/cryptodeal/zSockets/misc/valid_server_crt.pem",
        .ca_file_name = "/Users/cryptodeal/zSockets/misc/valid_ca_crt.pem",
    }, .{
        .key_file_name = "/Users/cryptodeal/zSockets/misc/selfsigned_client_key.pem",
        .cert_file_name = "/Users/cryptodeal/zSockets/misc/selfsigned_client_crt.pem",
        .ca_file_name = "/Users/cryptodeal/zSockets/misc/valid_ca_crt.pem",
    });

    try expectPeerVerify(allocator, "peer verify disabled", true, .{
        .key_file_name = "/Users/cryptodeal/zSockets/misc/valid_server_key.pem",
        .cert_file_name = "/Users/cryptodeal/zSockets/misc/valid_server_crt.pem",
    }, .{
        .key_file_name = "/Users/cryptodeal/zSockets/misc/valid_client_key.pem",
        .cert_file_name = "/Users/cryptodeal/zSockets/misc/valid_client_crt.pem",
    });
}
