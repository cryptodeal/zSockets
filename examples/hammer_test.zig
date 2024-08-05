const std = @import("std");
const zs = @import("zSockets");

const Allocator = std.mem.Allocator;

const PBSTR = "||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||";
const PBWIDTH = 60;

var last_val: i64 = -1;
fn printProgress(percentage: f64) void {
    const val: i64 = @intFromFloat(percentage * 100);
    if (last_val != -1 and val == last_val) {
        std.debug.print("progress: {d}\n", .{percentage});
        return;
    }
    last_val = val;
    const lpad: usize = @intFromFloat(percentage * PBWIDTH);
    // std.debug.print("\r{d}% [{s: <60}]", .{ val, PBSTR[0..lpad] });
    std.debug.print("{d}% [{s: <60}]\n", .{ val, PBSTR[0..lpad] });
}

var opened_connections: i64 = 0;
var closed_connections: i64 = 0;
var operations_done: i64 = 0;

var http_context: *zs.Context = undefined;
var websocket_context: *zs.Context = undefined;
var listen_socket: *zs.ListenSocket = undefined;

var opened_clients: i64 = 0;
var opened_servers: i64 = 0;
var closed_clients: i64 = 0;
var closed_servers: i64 = 0;

var long_buffer: []u8 = &[_]u8{};
const long_length: usize = 5 * 1024 * 1024;

const pad_should_always_be: f64 = 14.652752;

const HttpSocket = extern struct {
    pad_invariant: f64,
    is_http: bool,
    post_pad_invariant: f64,
    is_client: bool,
    content: [128]u8 = undefined,
};

const WebSocket = extern struct {
    pad_invariant: f64,
    is_http: bool,
    post_pad_invariant: f64,
    is_client: bool,
    content: [1024]u8 = undefined,
};

fn assumeState(s: *zs.Socket, is_http: bool) void {
    switch (is_http) {
        true => {
            const hs = s.ext(HttpSocket).?;
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
            const ws = s.ext(WebSocket).?;
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

const HttpCtx = extern struct {
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

fn performRandomOp(allocator: Allocator, s_: *zs.Socket) !*zs.Socket {
    var s = s_;
    const rand = getRng();
    switch (rand.uintAtMost(usize, 2147483647) % 5) {
        0 => return s.close(allocator, 0, null),
        1 => {
            if (!s.isClosed()) {
                if ((rand.uintAtMost(usize, 2147483647) % 2) != 0) {
                    s = try websocket_context.adoptSocket(allocator, s, WebSocket);
                    const ws = s.ext(WebSocket).?;
                    ws.is_http = false;
                } else {
                    s = try http_context.adoptSocket(allocator, s, HttpSocket);
                    const hs = s.ext(HttpSocket).?;
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
            s.ctx().loop.wakeup();
        },
        else => {},
    }
    return s;
}

fn onWakeup(_: Allocator, _: *zs.Loop) !void {
    std.debug.print("{s} @ {s}:{d}:{d}\n", .{ @src().fn_name, @src().file, @src().line, @src().column });
} // stub

fn onPre(_: Allocator, _: *zs.Loop) !void {
    std.debug.print("{s} @ {s}:{d}:{d}\n", .{ @src().fn_name, @src().file, @src().line, @src().column });
} // stub

fn onPost(_: Allocator, _: *zs.Loop) !void {
    std.debug.print("{s} @ {s}:{d}:{d}\n", .{ @src().fn_name, @src().file, @src().line, @src().column });
} // stub

fn onWebSocketWritable(allocator: Allocator, s: *zs.Socket) !*zs.Socket {
    std.debug.print("{s} @ {s}:{d}:{d}\n", .{ @src().fn_name, @src().file, @src().line, @src().column });
    assumeState(s, false);
    return performRandomOp(allocator, s);
}

fn onHttpSocketWritable(allocator: Allocator, s: *zs.Socket) !*zs.Socket {
    std.debug.print("{s} @ {s}:{d}:{d}\n", .{ @src().fn_name, @src().file, @src().line, @src().column });

    assumeState(s, true);
    return performRandomOp(allocator, s);
}

fn onWebSocketClose(allocator: Allocator, s: *zs.Socket, _: i32, _: ?*anyopaque) !*zs.Socket {
    std.debug.print("{s} @ {s}:{d}:{d}\n", .{ @src().fn_name, @src().file, @src().line, @src().column });
    assumeState(s, false);
    const ws = s.ext(WebSocket).?;
    switch (ws.is_client) {
        true => closed_clients += 1,
        else => closed_servers += 1,
    }
    closed_connections += 1;
    printProgress(@as(f64, @floatFromInt(closed_connections)) / 10000);
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

fn onHttpSocketClose(allocator: Allocator, s: *zs.Socket, _: i32, _: ?*anyopaque) !*zs.Socket {
    std.debug.print("{s} @ {s}:{d}:{d}\n", .{ @src().fn_name, @src().file, @src().line, @src().column });
    assumeState(s, true);
    const hs = s.ext(HttpSocket).?;
    switch (hs.is_client) {
        true => closed_clients += 1,
        else => closed_servers += 1,
    }
    closed_connections += 1;

    printProgress(@as(f64, @floatFromInt(closed_connections)) / 10000);
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

fn onWebSocketEnd(allocator: Allocator, s_: *zs.Socket) !*zs.Socket {
    std.debug.print("{s} @ {s}:{d}:{d}\n", .{ @src().fn_name, @src().file, @src().line, @src().column });
    var s = s_;
    assumeState(s, false);
    s = try s.close(allocator, 0, null);
    return performRandomOp(allocator, s);
}

fn onHttpSocketEnd(allocator: Allocator, s_: *zs.Socket) !*zs.Socket {
    std.debug.print("{s} @ {s}:{d}:{d}\n", .{ @src().fn_name, @src().file, @src().line, @src().column });
    var s = s_;
    assumeState(s, true);
    s = try s.close(allocator, 0, null);
    return performRandomOp(allocator, s);
}

fn onWebSocketData(allocator: Allocator, s: *zs.Socket, data: []u8) !*zs.Socket {
    std.debug.print("{s} @ {s}:{d}:{d}\n", .{ @src().fn_name, @src().file, @src().line, @src().column });
    assumeState(s, false);
    if (data.len == 0) @panic("ERROR: Got data event with no data\n");
    return performRandomOp(allocator, s);
}

fn onHttpSocketData(allocator: Allocator, s: *zs.Socket, data: []u8) !*zs.Socket {
    std.debug.print("{s} @ {s}:{d}:{d}\n", .{ @src().fn_name, @src().file, @src().line, @src().column });
    assumeState(s, true);
    if (data.len == 0) @panic("ERROR: Got data event with no data\n");
    return performRandomOp(allocator, s);
}

fn onWebSocketOpen(_: Allocator, _: *zs.Socket, _: bool, _: []u8) !*zs.Socket {
    std.debug.print("{s} @ {s}:{d}:{d}\n", .{ @src().fn_name, @src().file, @src().line, @src().column });
    @panic("ERROR: on_web_socket_open called!\n");
}

fn nextConnection(allocator: Allocator) !*zs.Socket {
    std.debug.print("{s} @ {s}:{d}:{d}\n", .{ @src().fn_name, @src().file, @src().line, @src().column });
    if (opened_clients == 5000) {
        @panic("ERROR! next_connection called when already having made all!\n");
    }
    return http_context.connect(allocator, HttpSocket, null, 3000, null, 0);
}

fn onHttpSocketConnectErr(allocator: Allocator, s: *zs.Socket, _: i32) !*zs.Socket {
    std.debug.print("{s} @ {s}:{d}:{d}\n", .{ @src().fn_name, @src().file, @src().line, @src().column });
    _ = try nextConnection(allocator);
    return s;
}

fn onWebSocketConnectErr(_: Allocator, _: *zs.Socket, _: i32) !*zs.Socket {
    std.debug.print("{s} @ {s}:{d}:{d}\n", .{ @src().fn_name, @src().file, @src().line, @src().column });
    @panic("ERROR: WebSocket can never get connect errors!\n");
}

fn onHttpSocketOpen(allocator: Allocator, s: *zs.Socket, is_client: bool, _: []u8) !*zs.Socket {
    std.debug.print("{s} @ {s}:{d}:{d}\n", .{ @src().fn_name, @src().file, @src().line, @src().column });
    const hs = s.ext(HttpSocket).?;
    hs.* = .{
        .is_http = true,
        .pad_invariant = pad_should_always_be,
        .post_pad_invariant = pad_should_always_be,
        .is_client = is_client,
    };

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

fn onWebSocketTimeout(allocator: Allocator, s: *zs.Socket) !*zs.Socket {
    std.debug.print("{s} @ {s}:{d}:{d}\n", .{ @src().fn_name, @src().file, @src().line, @src().column });
    assumeState(s, false);
    return performRandomOp(allocator, s);
}

var last_time: ?i64 = null;

fn onHttpSocketTimeout(allocator: Allocator, s: *zs.Socket) !*zs.Socket {
    std.debug.print("{s} @ {s}:{d}:{d}\n", .{ @src().fn_name, @src().file, @src().line, @src().column });
    if (!s.isEstablished()) {
        if (@intFromPtr(s) != @intFromPtr(listen_socket)) {
            @panic("CONNECTION TIMEOUT!!! CANNOT HAPPEN!!\n");
        }
        if (last_time != null and (std.time.timestamp() - last_time.?) == 0) {
            @panic("TIMER IS FIRING TOO FAST!!!\n");
        }

        last_time = std.time.timestamp();
        printProgress(@as(f64, @floatFromInt(closed_connections)) / 10000);
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
    const loop = try zs.Loop.init(allocator, null, null, &onWakeup, &onPre, &onPost);
    defer loop.deinit(allocator);

    http_context = try zs.Context.init(allocator, HttpCtx, loop);
    defer http_context.deinit(allocator);

    http_context.setOnOpen(&onHttpSocketOpen);
    http_context.setOnData(&onHttpSocketData);
    http_context.setOnWritable(&onHttpSocketWritable);
    http_context.setOnClose(&onHttpSocketClose);
    http_context.setOnTimeout(&onHttpSocketTimeout);
    http_context.setOnEnd(&onHttpSocketEnd);
    http_context.setOnConnectError(&onHttpSocketConnectErr);

    websocket_context = try http_context.initChildContext(allocator, HttpCtx);
    defer websocket_context.deinit(allocator);

    websocket_context.setOnOpen(@ptrCast(&onWebSocketOpen));
    websocket_context.setOnData(@ptrCast(&onWebSocketData));
    websocket_context.setOnWritable(@ptrCast(&onWebSocketWritable));
    websocket_context.setOnClose(@ptrCast(&onWebSocketClose));
    websocket_context.setOnTimeout(@ptrCast(&onWebSocketTimeout));
    websocket_context.setOnEnd(@ptrCast(&onWebSocketEnd));
    websocket_context.setOnConnectError(@ptrCast(&onWebSocketConnectErr));

    listen_socket = try http_context.listen(allocator, HttpSocket, null, 3000, 0);
    defer listen_socket.close() catch unreachable;
    listen_socket.s.setTimeout(16);

    std.debug.print("Running hammer test over tcpip\n", .{});
    printProgress(0);
    _ = try nextConnection(allocator);
    try loop.run(allocator);

    printProgress(1);
    std.debug.print("\n", .{});
    if (opened_clients == 5000 and closed_clients == 5000 and opened_servers == 5000 and closed_servers == 5000) {
        std.debug.print("ALL GOOD!\n", .{});
    } else {
        std.debug.print("MISMATCHING/FAILED!\n", .{});
    }
}
