const std = @import("std");
const zs = @import("zSockets");

const Allocator = std.mem.Allocator;
const HttpNetwork = zs.Network(false, .{ .socket = HttpSocket, .socket_ctx = HttpCtx });
const WebSocketNetwork = zs.Network(false, .{ .socket = WebSocket, .socket_ctx = HttpCtx });

const PBSTR = "||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||";
const PBWIDTH = 60;

var last_val: i64 = -1;
fn printProgress(percentage: f64) void {
    const val: i64 = @intFromFloat(percentage * 100);
    if (last_val != -1 and val == last_val) {
        return;
    }
    last_val = val;
    const lpad: usize = @intFromFloat(percentage * PBWIDTH);
    std.debug.print("\r{d} [{s: <60}]", .{ val, PBSTR[0..lpad] });
}

var opened_connections: i64 = 0;
var closed_connections: i64 = 0;
var operations_done: i64 = 0;

var http_context: *HttpNetwork.SocketCtx = undefined;
var websocket_context: *HttpNetwork.SocketCtx = undefined;
var listen_socket: *HttpNetwork.Socket.ListenSocket = undefined;

var opened_clients: i64 = 0;
var opened_servers: i64 = 0;
var closed_clients: i64 = 0;
var closed_servers: i64 = 0;

var long_buffer: []u8 = undefined;
const long_length: usize = 5 * 1024 * 1024;

const pad_should_always_be: f64 = 14.652752;

const HttpSocket = struct {
    pad_invariant: f64,
    is_http: bool,
    post_pad_invariant: f64,
    is_client: bool,
    content: [128]u8,
};

const WebSocket = struct {
    pad_invariant: f64,
    is_http: bool,
    post_pad_invariant: f64,
    is_client: bool,
    content: [1024]u8,
};

fn assumeState(s: *HttpNetwork.Socket, is_http: bool) void {
    switch (is_http) {
        true => {
            const hs = @as(*HttpSocket, @ptrCast(@alignCast(s.getExt())));
            if (hs.pad_invariant != pad_should_always_be or hs.post_pad_invariant != pad_should_always_be) {
                std.debug.panic(
                    \\ERROR: Pad invariant is not correct!
                    \\pad_invariant is: {d} should be: {d}
                    \\post_pad_invariant is: {d} should be: {d}
                , .{ hs.pad_invariant, pad_should_always_be, hs.post_pad_invariant, pad_should_always_be });
            }
            if (hs.is_http != is_http) {
                std.debug.panic("ERROR: State is: {any} should be: {any}. Terminating now!\n", .{ hs.is_http, is_http });
            }
            @memset(hs.content[0..128], 0);
        },
        else => {
            const ws = @as(*WebSocket, @ptrCast(@alignCast(s.getExt())));
            if (ws.pad_invariant != pad_should_always_be or ws.post_pad_invariant != pad_should_always_be) {
                std.debug.panic(
                    \\ERROR: Pad invariant is not correct!
                    \\pad_invariant is: {d} should be: {d}
                    \\post_pad_invariant is: {d} should be: {d}
                , .{ ws.pad_invariant, pad_should_always_be, ws.post_pad_invariant, pad_should_always_be });
            }
            if (ws.is_http != is_http) {
                std.debug.panic("ERROR: State is: {any} should be: {any}. Terminating now!\n", .{ ws.is_http, is_http });
            }
            @memset(ws.content[0..1024], 0);
        },
    }
}

const HttpCtx = struct {
    content: [1]u8,
};

var prng: ?std.Random.Xoshiro256 = null;
var rand_: std.Random = undefined;

fn getRng() std.Random {
    if (prng == null) {
        prng = std.Random.DefaultPrng.init(blk: {
            var seed: u64 = undefined;
            std.posix.getrandom(std.mem.asBytes(&seed)) catch unreachable;
            break :blk seed;
        });
        rand_ = prng.?.random();
    }
    return rand_;
}

fn performRandomOp(allocator: Allocator, s_: *HttpNetwork.Socket) !*HttpNetwork.Socket {
    var s = s_;
    const rand = getRng();
    switch (rand.uintAtMost(usize, 2147483647) % 5) {
        0 => return s.close(allocator, 0, null),
        1 => {
            if (!s.isClosed()) {
                if ((rand.uintAtMost(usize, 2147483647) % 2) != 0) {
                    s = try websocket_context.adoptSocket(allocator, s);
                    const hs: *HttpSocket = @ptrCast(@alignCast(s.getExt()));
                    hs.is_http = false;
                } else {
                    s = try http_context.adoptSocket(allocator, s);
                    const hs: *HttpSocket = @ptrCast(@alignCast(s.getExt()));
                    hs.is_http = true;
                }
            }
            return performRandomOp(allocator, s);
        },
        2 => {
            // write - causes the other end to receive the data (event) and possibly us
            // to receive on writable event - could it be that we get stuck if the other end is closed?
            // no because, if we do not get ack in time we will timeout after some time
            _ = try s.write(long_buffer[0 .. rand.uintAtMost(usize, 2147483647) % long_length], false);
        },
        3 => {
            // shutdown (on macOS we can get stuck in fin_wait_2 for some weird reason!)
            // if we send fin, the other end sends data but then on writable closes? then fin is not sent?
            // so we need to timeout here to ensure we are closed if no fin is received within 30 seconds
            try s.shutdown();
            s.setTimeout(16);
        },
        4 => {
            // Triggers all timeouts next iteration
            s.setTimeout(4);
            try zs.wakeupLoop(s.getCtx().getLoop());
        },
        else => {},
    }
    return s;
}

fn onWakeup(_: Allocator, _: *HttpNetwork.Loop) !void {} // stub

fn onPre(_: Allocator, _: *HttpNetwork.Loop) !void {} // stub

fn onPost(_: Allocator, _: *HttpNetwork.Loop) !void {} // stub

fn onWebSocketWritable(allocator: Allocator, s: *HttpNetwork.Socket) !*HttpNetwork.Socket {
    assumeState(s, false);
    return performRandomOp(allocator, s);
}

fn onHttpSocketWritable(allocator: Allocator, s: *HttpNetwork.Socket) !*HttpNetwork.Socket {
    assumeState(s, true);
    return performRandomOp(allocator, s);
}

fn onWebSocketClose(allocator: Allocator, s: *HttpNetwork.Socket, _: i32, _: ?*anyopaque) !*HttpNetwork.Socket {
    assumeState(s, false);
    const ws: *WebSocket = @ptrCast(@alignCast(s.getExt()));
    switch (ws.is_client) {
        true => closed_clients += 1,
        else => closed_servers += 1,
    }
    closed_connections += 1;
    printProgress(@floatFromInt(@divTrunc(closed_connections, 10000)));
    if (closed_connections == 10000) {
        if (opened_clients != 5000) {
            std.debug.panic("ERROR: list closed before opening all clients!?!? {d}\n", .{opened_clients});
        }
        try listen_socket.close();
    } else {
        return performRandomOp(allocator, s);
    }
    return s;
}

fn onHttpSocketClose(allocator: Allocator, s: *HttpNetwork.Socket, _: i32, _: ?*anyopaque) !*HttpNetwork.Socket {
    assumeState(s, true);
    const hs: *HttpSocket = @ptrCast(@alignCast(s.getExt()));
    switch (hs.is_client) {
        true => closed_clients += 1,
        else => closed_servers += 1,
    }
    closed_connections += 1;
    printProgress(@floatFromInt(@divTrunc(closed_connections, 10000)));
    if (closed_connections == 10000) {
        if (opened_clients != 5000) {
            std.debug.panic("ERROR: list closed before opening all clients!?!? {d}\n", .{opened_clients});
        }
        try listen_socket.close();
    } else {
        return performRandomOp(allocator, s);
    }
    return s;
}

fn onWebSocketEnd(allocator: Allocator, s_: *HttpNetwork.Socket) !*HttpNetwork.Socket {
    var s = s_;
    assumeState(s, false);
    s = try s.close(allocator, 0, null);
    return performRandomOp(allocator, s);
}

fn onHttpSocketEnd(allocator: Allocator, s_: *HttpNetwork.Socket) !*HttpNetwork.Socket {
    var s = s_;
    assumeState(s, true);
    s = try s.close(allocator, 0, null);
    return performRandomOp(allocator, s);
}

fn onWebSocketData(allocator: Allocator, s: *HttpNetwork.Socket, data: []u8) !*HttpNetwork.Socket {
    assumeState(s, false);
    if (data.len == 0) @panic("ERROR: Got data event with no data\n");
    return performRandomOp(allocator, s);
}

fn onHttpSocketData(allocator: Allocator, s: *HttpNetwork.Socket, data: []u8) !*HttpNetwork.Socket {
    assumeState(s, true);
    if (data.len == 0) @panic("ERROR: Got data event with no data\n");
    return performRandomOp(allocator, s);
}

fn onWebSocketOpen(_: Allocator, _: *HttpNetwork.Socket, _: bool, _: []u8) !*HttpNetwork.Socket {
    @panic("ERROR: on_web_socket_open called!\n");
}

fn nextConnection(allocator: Allocator) !*HttpNetwork.Socket {
    if (opened_clients == 5000) {
        @panic("ERROR! next_connection called when already having made all!\n");
    }
    if (try http_context.connect(allocator, "127.0.0.1", 3000, null, 0)) |cxn_socket| return cxn_socket;
    @panic("ERROR: Failed to start connection!\n");
}

fn onHttpSocketConnectErr(allocator: Allocator, s: *HttpNetwork.Socket, _: i32) !*HttpNetwork.Socket {
    _ = try nextConnection(allocator);
    return s;
}

fn onWebSocketConnectErr(_: Allocator, _: *HttpNetwork.Socket, _: i32) !*HttpNetwork.Socket {
    @panic("ERROR: WebSocket can never get connect errors!\n");
}

fn onHttpSocketOpen(allocator: Allocator, s: *HttpNetwork.Socket, is_client: bool, _: []u8) !*HttpNetwork.Socket {
    const hs: *HttpSocket = @ptrCast(s.getExt());
    hs.is_http = true;
    hs.pad_invariant = pad_should_always_be;
    hs.post_pad_invariant = pad_should_always_be;
    hs.is_client = is_client;

    assumeState(s, true);
    opened_connections += 1;
    switch (is_client) {
        true => opened_clients += 1,
        else => opened_servers += 1,
    }
    if (is_client and opened_clients < 5000) {
        _ = try nextConnection(allocator);
    }
    return performRandomOp(allocator, s);
}

fn onWebSocketTimeout(allocator: Allocator, s: *HttpNetwork.Socket) !*HttpNetwork.Socket {
    assumeState(s, false);
    return performRandomOp(allocator, s);
}

var last_time: ?i64 = null;

fn onHttpSocketTimeout(allocator: Allocator, s: *HttpNetwork.Socket) !*HttpNetwork.Socket {
    if (!s.isEstablished()) {
        if (s != @as(*HttpNetwork.Socket, @ptrCast(@alignCast(listen_socket)))) {
            @panic("CONNECTION TIMEOUT!!! CANNOT HAPPEN!!\n");
        }
        if (last_time != null and (std.time.timestamp() - last_time.?) == 0) {
            @panic("TIMER IS FIRING TOO FAST!!!\n");
        }

        last_time = std.time.timestamp();
        printProgress(@floatFromInt(@divTrunc(closed_connections, 10000)));
        s.setTimeout(16);
        return s;
    }
    assumeState(s, true);
    if (s.isShutdown()) {
        return s.close(allocator, 0, null);
    }
    return performRandomOp(allocator, s);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    long_buffer = try allocator.alloc(u8, long_length * 1);
    defer allocator.free(long_buffer);
    const loop = try HttpNetwork.Loop.init(allocator, null, &onWakeup, &onPre, &onPost);

    http_context = try HttpNetwork.SocketCtx.init(allocator, loop);

    http_context.setOnOpen(&onHttpSocketOpen);
    http_context.setOnData(&onHttpSocketData);
    http_context.setOnWritable(&onHttpSocketWritable);
    http_context.setOnClose(&onHttpSocketClose);
    http_context.setOnTimeout(&onHttpSocketTimeout);
    http_context.setOnEnd(&onHttpSocketEnd);
    http_context.setOnConnectError(&onHttpSocketConnectErr);

    websocket_context = @ptrCast(@alignCast(try WebSocketNetwork.SocketCtx.init(allocator, @ptrCast(@alignCast(loop)))));

    websocket_context.setOnOpen(@ptrCast(&onWebSocketOpen));
    websocket_context.setOnData(@ptrCast(&onWebSocketData));
    websocket_context.setOnWritable(@ptrCast(&onWebSocketWritable));
    websocket_context.setOnClose(@ptrCast(&onWebSocketClose));
    websocket_context.setOnTimeout(@ptrCast(&onWebSocketTimeout));
    websocket_context.setOnEnd(@ptrCast(&onWebSocketEnd));
    websocket_context.setOnConnectError(@ptrCast(&onWebSocketConnectErr));

    listen_socket = try http_context.listen(allocator, "127.0.0.1", 3000, 0);
    @as(*HttpNetwork.Socket, @ptrCast(@alignCast(listen_socket))).setTimeout(16);

    std.debug.print("Running hammer test over tcpip\nListening on port 3000\n", .{});
    printProgress(0);
    _ = try nextConnection(allocator);
    try loop.run(allocator);

    websocket_context.deinit(allocator);
    http_context.deinit(allocator);
    loop.deinit(allocator);
    printProgress(1);
    std.debug.print("\n", .{});
    if (opened_clients == 5000 and closed_clients == 5000 and opened_servers == 5000 and closed_servers == 5000) {
        std.debug.print("ALL GOOD!\n", .{});
    } else {
        std.debug.print("MISMATCHING/FAILED!\n", .{});
    }
}
