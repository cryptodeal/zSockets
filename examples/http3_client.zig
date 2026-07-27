const std = @import("std");
const zs = @import("zSockets");

var context: *zs.quic.SocketContext = undefined;
var responses: usize = 0;
var loop: *zs.Loop = undefined;

fn onWakeup(_: std.mem.Allocator, _: *zs.Loop) !void {}

fn onPre(_: std.mem.Allocator, _: *zs.Loop) !void {}

fn onPost(_: std.mem.Allocator, _: *zs.Loop) !void {}

var per_socket_requests: [100]u32 = undefined;
var sockets: [100]*zs.quic.Socket = undefined;
var num_sockets: usize = 0;

fn onPrint(_: std.mem.Allocator, _: *zs.Timer) !void {
    std.debug.print("Responses per second: {d}\n", .{responses});
    responses = 0;
    for (0..num_sockets) |i| {
        if (per_socket_requests[i] == 0) {
            std.debug.print("One socket had no responses, closing!\n", .{});
            std.process.exit(0);
        }
        std.debug.print("Responses per second for socket {d}: {d}\n", .{ i, per_socket_requests[i] });
        per_socket_requests[i] = 0;
    }
}

fn printCurrentHeaders() void {
    var i: usize = 0;
    var more = true;
    while (more) : (i += 1) {
        var name: []u8 = undefined;
        var value: []u8 = undefined;
        more = context.getHeader(i, &name, &value);
        if (more) {
            std.debug.print("header {s} = {s}\n", .{ name, value });
        }
    }
}

fn onStreamHeaders(_: std.mem.Allocator, s: ?*anyopaque) !void {
    for (0..num_sockets) |i| {
        if (sockets[i] == zs.quic.streamSocket(s)) {
            per_socket_requests[i] += 1;
            break;
        }
        if (i == num_sockets - 1) {
            std.debug.print("Got response from socket we do not even have open!\n", .{});
            std.process.exit(0);
        }
    }

    //printf("Response from %p\n", us_quic_stream_socket(s));

    responses += 1;
    //if (responses == 10) {
    //on_print(NULL);
    //}

    //printf("CLIENT GOT HTTP RESPONSE!\n");

    //print_current_headers();

    // Make a new stream
    zs.quic.streamSocket(s).createStream(null);
}

fn onStreamData(_: std.mem.Allocator, _: ?*anyopaque, _: []u8) !void {}

fn onStreamWritable(_: std.mem.Allocator, _: ?*anyopaque) !void {}

fn onStreamClose(_: std.mem.Allocator, _: ?*anyopaque) !void {}

var ignore = false;

fn onStart(allocator: std.mem.Allocator, _: *zs.Timer) !void {
    if (num_sockets < 10) {
        _ = try context.connect(allocator, "::1", 9004, null);
    } else {
        if (!ignore) {
            const delay_timer = try zs.createTimer(allocator, loop, false, null);
            zs.timerSet(delay_timer, &onPrint, 1000, 1000);
            ignore = true;
            std.debug.print("Starting now\n", .{});
            for (0..num_sockets) |i| {
                for (0..32) |_| {
                    sockets[i].createStream(null);
                }
            }
        }
    }
}

fn onOpen(_: std.mem.Allocator, s: *zs.quic.Socket, is_client: bool) !void {
    std.debug.print("New QUIC connection! Is client: {any}\n", .{is_client});
    // for now the lib creates a stream by itself here if client
    if (is_client) {
        sockets[num_sockets] = s;
        num_sockets += 1;
    } else {
        std.debug.print("yololooo\n", .{});
        std.process.exit(0);
    }
}

fn onStreamOpen(_: std.mem.Allocator, s: ?*anyopaque, is_client: bool) !void {
    // std.debug.print("Stream open is_client: {d}!\n", .{is_client});
    // The client begins by making a request
    if (is_client) {
        try context.setHeader(0, ":method", "GET");
        // try context.setHeader(1, ":path", "/hi");
        try context.sendHeaders(s, 1, false);
        // Shutdown writing (send FIN)
        zs.quic.streamShutdown(s);
    }
}

fn onClose(_: std.mem.Allocator, _: *zs.quic.Socket) !void {
    std.debug.print("QUIC connection closed!\n", .{});
}

pub fn main(_: std.process.Init) !void {
    // var gpa = std.heap.DebugAllocator(.{}){};
    // defer std.debug.assert(gpa.deinit() == .ok);
    // const allocator = gpa.allocator();

    const allocator = std.heap.smp_allocator;

    loop = try zs.Loop.init(allocator, null, &onWakeup, &onPre, &onPost, null);
    defer loop.deinit(allocator);

    const options: zs.quic.SocketContext.Options = .{};

    context = try zs.quic.SocketContext.init(allocator, loop, options, null);
    context.setOnStreamData(&onStreamData);
    context.setOnStreamOpen(&onStreamOpen);
    context.setOnStreamClose(&onStreamClose);
    context.setOnStreamWritable(&onStreamWritable);
    context.setOnStreamHeaders(&onStreamHeaders);
    context.setOnOpen(&onOpen);
    context.setOnClose(&onClose);

    const start_timer = try zs.createTimer(allocator, loop, false, null);
    defer zs.timerClose(allocator, start_timer);
    zs.timerSet(start_timer, &onStart, 100, 100);

    // We also establish a client connection that sends requests
    // for (0..4) |_| {
    //     _ = try context.connect(allocator, "::1", 9004, null);
    // }

    // Run the event loop
    try loop.run(allocator);
    std.debug.print("Falling through!\n", .{});
}
