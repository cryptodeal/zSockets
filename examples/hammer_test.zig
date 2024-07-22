const std = @import("std");
const zs = @import("zSockets");

const Allocator = std.mem.Allocator;

const ssl = false;
const PBSTR = "||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||";
const PBWIDTH = 60;

var last_val: i64 = -1;
fn printProgress(percentage: f64) void {
    const val: i64 = @intFromFloat(percentage * 100);
    if (last_val != -1 and val == last_val) {
        return;
    }
    last_val = val;
    const rpad: i64 = PBWIDTH - @as(i64, @intFromFloat(percentage * PBWIDTH));
    std.log.info("\r{d} {s}", .{ val, PBSTR[0..rpad] });
}

var opened_connections: i64 = 0;
var closed_connections: i64 = 0;
var operations_done: i64 = 0;

var http_context: *zs.SocketCtx = undefined;
var websocket_context: *zs.SocketCtx = undefined;
var listen_socket: *zs.ListenSocket = undefined;

var opened_clients: i64 = 0;
var opened_servers: i64 = 0;
var closed_clients: i64 = 0;
var closed_servers: i64 = 0;

var long_buffer: ?[]u8 = undefined;
var long_length: usize = 5 * 1024 * 1024;

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

fn assumeState(s: *zs.Socket, is_http: bool) void {
    const hs: *HttpSocket = @ptrCast(@alignCast(s.getExt(ssl)));
    if (hs.pad_invariant != pad_should_always_be or hs.post_pad_invariant != pad_should_always_be) {
        @panic("ERROR: Pad invariant is not correct!\n");
    }
    if (hs.is_http != is_http) {
        std.debug.panic("ERROR: State is: {any} should be: {any}. Terminating now!\n", .{ hs.is_http, is_http });
    }

    // try and cause havoc (different size)
    if (hs.is_http) {
        @memset(hs.content[0..128], 0);
    } else {
        @memset(hs.content[0..1024], 0);
    }
}

const HttpCtx = struct {
    content: [1]u8,
};

var prng: ?std.rand.Xoshiro256 = null;
var rand_: std.Random = undefined;

fn getRng() !std.Random {
    if (prng == null) {
        prng = std.rand.DefaultPrng.init(blk: {
            var seed: u64 = undefined;
            try std.os.getrandom(std.mem.asBytes(&seed));
            break :blk seed;
        });
        rand_ = prng.?.random();
    }
    return rand_;
}

fn performRandomOp(allocator: Allocator, s_: *zs.Socket) !*zs.Socket {
    var s = s_;
    const rand = try getRng();
    switch ((rand.uintAtMost(usize, 2147483647) % 5) != 0) {
        0 => return s.close(allocator, ssl, 0, null),
        1 => {
            if (!s.isClosed(false)) {
                if ((rand.uintAtMost(usize, 2147483647) % 2) != 0) {
                    s = try websocket_context.adoptSocket(allocator, ssl, s, @sizeOf(WebSocket));
                    const hs: *HttpSocket = @ptrCast(@alignCast(s.getExt(ssl)));
                    hs.is_http = false;
                } else {
                    s = try http_context.adoptSocket(allocator, ssl, s, @sizeOf(HttpSocket));
                    const hs: *HttpSocket = @ptrCast(@alignCast(s.getExt(ssl)));
                    hs.is_http = true;
                }
            }
            return performRandomOp(allocator, s);
        },
        2 => {
            // write - causes the other end to receive the data (event) and possibly us
            // to receive on writable event - could it be that we get stuck if the other end is closed?
            // no because, if we do not get ack in time we will timeout after some time
            try s.write(ssl, long_buffer.?[0 .. rand.uintAtMost(usize, 2147483647) % long_length], false);
        },
        3 => {
            // shutdown (on macOS we can get stuck in fin_wait_2 for some weird reason!)
            // if we send fin, the other end sends data but then on writable closes? then fin is not sent?
            // so we need to timeout here to ensure we are closed if no fin is received within 30 seconds
            try s.shutdown(ssl);
            s.setTimeout(ssl, 16);
        },
        4 => {
            // Triggers all timeouts next iteration
            s.setTimeout(ssl, 4);
            try zs.wakeupLoop(s.getCtx(ssl).getLoop(ssl));
        },
    }
    return s;
}

fn onWakeup(_: *zs.Loop) void {} // stub

fn onPre(_: *zs.Loop) void {} // stub

fn onPost(_: *zs.Loop) void {} // stub

fn onWebSocketWritable(allocator: Allocator, s: *zs.Socket) !*zs.Socket {
    try assumeState(s, false);
    return performRandomOp(allocator, s);
}

fn onHttpSocketWritable(allocator: Allocator, s: *zs.Socket) !*zs.Socket {
    try assumeState(s, true);
    return performRandomOp(allocator, s);
}

fn onWebSocketClose(allocator: Allocator, s: *zs.Socket, _: i32, _: ?*anyopaque) !*zs.Socket {
    try assumeState(s, false);
    const ws: *WebSocket = @ptrCast(@alignCast(s.getExt(ssl)));
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
        try listen_socket.close(ssl);
    } else {
        return performRandomOp(allocator, s);
    }
    return s;
}

fn onHttpSocketClose(allocator: Allocator, s: *zs.Socket, _: i32, _: ?*anyopaque) !*zs.Socket {
    try assumeState(s, true);
    const hs: *HttpSocket = @ptrCast(@alignCast(s.getExt(ssl)));
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
        try listen_socket.close(ssl);
    } else {
        return performRandomOp(allocator, s);
    }
    return s;
}

fn onWebSocketEnd(allocator: Allocator, s: *zs.Socket) !*zs.Socket {
    assumeState(s, false);
    s = try s.close(allocator, ssl, 0, null);
    return performRandomOp(allocator, s);
}

fn onHttpSocketEnd(allocator: Allocator, s: *zs.Socket) !*zs.Socket {
    assumeState(s, true);
    s = try s.close(allocator, ssl, 0, null);
    return performRandomOp(allocator, s);
}

fn onWebSocketData(allocator: Allocator, s: *zs.Socket, data: []u8) !*zs.Socket {
    assumeState(s, false);
    if (data.len == 0) @panic("ERROR: Got data event with no data\n");
    return performRandomOp(allocator, s);
}

fn onHttpSocketData(allocator: Allocator, s: *zs.Socket, data: []u8) !*zs.Socket {
    assumeState(s, true);
    if (data.len == 0) @panic("ERROR: Got data event with no data\n");
    return performRandomOp(allocator, s);
}

fn onWebSocketOpen(_: Allocator, _: *zs.Socket, _: bool, _: []u8) !*zs.Socket {
    @panic("ERROR: on_web_socket_open called!\n");
}

fn nextConnection() !*zs.Socket {
    if (opened_clients == 5000) {
        @panic("ERROR! next_connection called when already having made all!\n");
    }
    var connection_socket: *zs.Socket = undefined;
    if (!(connection_socket = ))
}
