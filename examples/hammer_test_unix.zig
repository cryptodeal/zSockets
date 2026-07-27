const std = @import("std");
const zs = @import("zSockets");

const ssl = true;

const pb_str = "||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||";

const State = struct {
    io: std.Io,
    // for `printProgress`
    last_val: i32 = -1,
    buffer: [1024]u8 = undefined,

    pub fn printProgress(self: *State, percentage: f64) !void {
        const val: i32 = @intFromFloat(percentage * 100);
        if (self.last_val != -1 and val == self.last_val) return;
        self.last_val = val;
        const lpad: usize = @intFromFloat(percentage * pb_str.len);
        var stdout_writer = std.Io.File.stdout().writer(self.io, &self.buffer);
        try stdout_writer.interface.print("\r{d:3}% [{s: <60}]", .{ val, pb_str[0..lpad] });
        try stdout_writer.interface.flush();
    }
};

var state: State = undefined;
var opened_connections: usize = 0;
var closed_connections: usize = 0;
var operations_done: usize = 0;

var http_context: *zs.SocketContext = undefined;
var websocket_context: *zs.SocketContext = undefined;
var listen_socket: *zs.ListenSocket = undefined;

var opened_clients: usize = 0;
var opened_servers: usize = 0;
var closed_clients: usize = 0;
var closed_servers: usize = 0;

var long_buffer: []u8 = undefined;
const long_length = 5 * 1024 * 1024;
const pad_should_always_be: f64 = 14.652752;

const HttpSocket = extern struct {
    pad_invariant: f64,
    is_http: bool,
    post_pad_invariant: f64,
    is_client: bool,
    content: [128]u8,
};

const WebSocket = extern struct {
    pad_invariant: f64,
    is_http: bool,
    post_pad_invariant: f64,
    is_client: bool,
    content: [1024]u8,
};
var prng: std.Random.DefaultPrng = undefined;
var rand: std.Random = undefined;

fn assumeState(s: *zs.Socket, is_http: bool) void {
    if (is_http) {
        const hs = s.getExt(HttpSocket).?;
        if (hs.pad_invariant != pad_should_always_be or hs.post_pad_invariant != pad_should_always_be) {
            std.debug.print("ERROR: Pad invariant is not correct!\n", .{});
            // std.debug.print("Failed socket ptr: {d}\n", .{@intFromPtr(s)});
            std.process.abort();
        }
        if (hs.is_http != is_http) {
            std.debug.print("ERROR: State is: {d} should be: {d}. Terminating now!\n", .{ @intFromBool(hs.is_http), @intFromBool(is_http) });
            // std.debug.print("Failed socket ptr: {d}\n", .{@intFromPtr(s)});
            std.process.abort();
        }
        @memset(&hs.content, 0);
    } else {
        const hs = s.getExt(WebSocket).?;
        if (hs.pad_invariant != pad_should_always_be or hs.post_pad_invariant != pad_should_always_be) {
            std.debug.print("ERROR: Pad invariant is not correct!\n", .{});
            // std.debug.print("Failed socket ptr: {d}\n", .{@intFromPtr(s)});
            std.process.abort();
        }
        if (hs.is_http != is_http) {
            std.debug.print("ERROR: State is: {d} should be: {d}. Terminating now!\n", .{ @intFromBool(hs.is_http), @intFromBool(is_http) });
            // std.debug.print("Failed socket ptr: {d}\n", .{@intFromPtr(s)});
            std.process.abort();
        }
        @memset(&@as(*WebSocket, @ptrCast(@alignCast(hs))).content, 0);
    }
}

const HttpContext = struct {
    content: [1]u8,
};

fn performRandomOperation(allocator: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    var s_ = s;
    switch (rand.int(u32) % 5) {
        0 => return s_.close(allocator, ssl, 0, null),
        1 => {
            if (!s_.isClosed(ssl)) {
                if ((rand.int(u32) % 2) != 0) {
                    s_ = try websocket_context.adoptSocket(allocator, ssl, s_, WebSocket);
                    const hs = s_.getExt(WebSocket).?;
                    hs.is_http = false;
                } else {
                    s_ = try http_context.adoptSocket(allocator, ssl, s_, HttpSocket);
                    const hs = s_.getExt(HttpSocket).?;
                    hs.is_http = true;
                }
            }
            return performRandomOperation(allocator, s_);
        },
        2 => {
            _ = s_.write(ssl, long_buffer[0 .. rand.int(usize) % long_length], false);
        },
        3 => {
            s_.shutdown(ssl);
            s_.setTimeout(ssl, 16);
        },
        4 => {
            s_.setTimeout(ssl, 4);
            zs.loop.wakeupLoop(s_.context.loop);
        },
        else => {},
    }
    return s_;
}

fn onWakeup(_: std.mem.Allocator, _: *zs.Loop) !void {
    // TODO: call `zs.loop.timerSweep` to expose bugs
    // try zs.loop.internalTimerSweep(allocator, loop);
}

fn onPre(_: std.mem.Allocator, _: *zs.Loop) !void {}

fn onPost(_: std.mem.Allocator, _: *zs.Loop) !void {}

fn onWebSocketWritable(allocator: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    assumeState(s, false);
    return performRandomOperation(allocator, s);
}

fn onHttpSocketWritable(allocator: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    assumeState(s, true);
    return performRandomOperation(allocator, s);
}

fn onWebSocketClose(allocator: std.mem.Allocator, s: *zs.Socket, _: i32, _: ?*anyopaque) !*zs.Socket {
    assumeState(s, false);
    const ws: *WebSocket = s.getExt(WebSocket).?;
    if (ws.is_client) {
        closed_clients += 1;
    } else {
        closed_servers += 1;
    }
    closed_connections += 1;
    try state.printProgress(@as(f64, @floatFromInt(closed_connections)) / 10000);
    if (closed_connections == 10000) {
        if (opened_clients != 5000) {
            std.debug.print("WHY THE HELL IS THE LIST CLOSING BEFORE ALL CLIENTS ARE OPEN! {d}\n", .{opened_clients});
            std.c.exit(1);
        }
        listen_socket.close(ssl);
    } else {
        return performRandomOperation(allocator, s);
    }
    return s;
}

fn onHttpSocketClose(allocator: std.mem.Allocator, s: *zs.Socket, _: i32, _: ?*anyopaque) !*zs.Socket {
    assumeState(s, true);
    const hs: *HttpSocket = s.getExt(HttpSocket).?;
    if (hs.is_client) {
        closed_clients += 1;
    } else {
        closed_servers += 1;
    }
    try state.printProgress(@as(f64, @floatFromInt(closed_connections)) / 10000);
    closed_connections += 1;
    if (closed_connections == 10000) {
        if (opened_clients != 5000) {
            std.debug.print("WHY THE HELL IS THE LIST CLOSING BEFORE ALL CLIENTS ARE OPEN! {d}\n", .{opened_clients});
            std.c.exit(1);
        }
        listen_socket.close(ssl);
    } else {
        return performRandomOperation(allocator, s);
    }
    return s;
}

fn onWebSocketEnd(allocator: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    var s_ = s;
    assumeState(s_, false);
    s_ = try s_.close(allocator, ssl, 0, null);
    return performRandomOperation(allocator, s_);
}

fn onHttpSocketEnd(allocator: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    var s_ = s;
    assumeState(s_, true);
    s_ = try s_.close(allocator, ssl, 0, null);
    return performRandomOperation(allocator, s_);
}

fn onWebSocketData(allocator: std.mem.Allocator, s: *zs.Socket, data: []u8) !*zs.Socket {
    assumeState(s, false);
    if (data.len == 0) {
        std.debug.print("ERROR: Got data event with no data\n", .{});
        std.c.exit(-1);
    }
    return performRandomOperation(allocator, s);
}

fn onHttpSocketData(allocator: std.mem.Allocator, s: *zs.Socket, data: []u8) !*zs.Socket {
    assumeState(s, true);
    if (data.len == 0) {
        std.debug.print("ERROR: Got data event with no data\n", .{});
        std.c.exit(-1);
    }
    return performRandomOperation(allocator, s);
}

fn onWebSocketOpen(_: std.mem.Allocator, s: *zs.Socket, _: bool, _: []u8) !*zs.Socket {
    std.debug.print("ERROR: `onWebSocketOpen` called!\n", .{});
    std.c.exit(-2);
    return s;
}

fn nextConnection(allocator: std.mem.Allocator) !*zs.Socket {
    if (opened_clients == 5000) {
        std.debug.print("ERROR! next_connection called when already having made all!\n", .{});
        std.c.abort();
    }
    if (http_context.connectUnix(allocator, ssl, "hammer_test.sock", 0, HttpSocket)) |connection_socket| {
        return connection_socket;
    } else |_| {
        std.debug.print("FAILED TO START CONNECTION, WILL EXIT NOW\n", .{});
        std.c.exit(1);
    }
}

fn onHttpSocketConnectError(allocator: std.mem.Allocator, s: *zs.Socket, _: i32) !*zs.Socket {
    _ = try nextConnection(allocator);
    return s;
}

fn onWebSocketConnectError(_: std.mem.Allocator, s: *zs.Socket, _: i32) !*zs.Socket {
    std.debug.print("ERROR: WebSocket can never get connect errors!\n", .{});
    std.c.exit(1);
    return s;
}

fn onHttpSocketOpen(allocator: std.mem.Allocator, s: *zs.Socket, is_client: bool, _: []u8) !*zs.Socket {
    const hs = s.getExt(HttpSocket).?;
    hs.is_http = true;
    hs.pad_invariant = pad_should_always_be;
    hs.post_pad_invariant = pad_should_always_be;
    hs.is_client = is_client;
    assumeState(s, true);
    opened_connections += 1;
    if (is_client) {
        opened_clients += 1;
    } else {
        opened_servers += 1;
    }
    if (is_client and opened_clients < 5000) {
        _ = try nextConnection(allocator);
    }
    return performRandomOperation(allocator, s);
}

fn onWebSocketTimeout(allocator: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    assumeState(s, false);
    return performRandomOperation(allocator, s);
}

var last_time: ?std.Io.Timestamp = null;

fn onHttpSocketTimeout(allocator: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    if (!s.isEstablished(ssl)) {
        if (s != @as(*zs.Socket, @ptrCast(@alignCast(listen_socket)))) {
            std.debug.print("CONNECTION TIMEOUT!!! CANNOT HAPPEN!!\n", .{});
            std.c.exit(1);
            // would be valid to do the following, but we care about count (see uSockets original code)
            _ = s.closeConnecting(ssl);
            _ = try nextConnection(allocator);
        }

        if (last_time) |lt| {
            if (std.Io.Clock.real.now(state.io).toSeconds() - lt.toSeconds() == 0) {
                std.debug.print("TIMER IS FIRING TOO FAST!!!\n", .{});
                std.c.exit(1);
            }
        }
        last_time = std.Io.Clock.real.now(state.io);

        try state.printProgress(@as(f64, @floatFromInt(closed_connections)) / 10000);
        s.setTimeout(ssl, 16);
        return s;
    }
    assumeState(s, true);
    if (s.isShutdown(ssl)) {
        return s.close(allocator, ssl, 0, null);
    }
    return performRandomOperation(allocator, s);
}

pub fn main(init: std.process.Init) !void {
    state = .{ .io = init.io };
    // var gpa = std.heap.DebugAllocator(.{}){};
    // defer std.debug.assert(gpa.deinit() == .ok);
    // const allocator = gpa.allocator();

    const allocator = std.heap.smp_allocator;

    prng = .init(@intCast(std.Io.Clock.real.now(state.io).toSeconds()));
    rand = prng.random();
    long_buffer = try allocator.alloc(u8, long_length);
    defer allocator.free(long_buffer);

    const loop = try zs.Loop.init(allocator, null, &onWakeup, &onPre, &onPost, null);
    defer loop.deinit(allocator);

    // TODO: enable SSL and pass relevant options
    const options: zs.SocketContextOptions = .{
        .key_file_name = "/Users/cryptodeal/zSockets/misc/valid_server_key.pem",
        .cert_file_name = "/Users/cryptodeal/zSockets/misc/valid_server_crt.pem",
        .passphrase = "1234",
    };
    http_context = try zs.SocketContext.init(allocator, ssl, loop, options, HttpContext);
    defer http_context.deinit(allocator);

    http_context.setOnOpen(ssl, &onHttpSocketOpen);
    http_context.setOnData(ssl, &onHttpSocketData);
    http_context.setOnWritable(ssl, &onHttpSocketWritable);
    http_context.setOnClose(ssl, &onHttpSocketClose);
    http_context.setOnTimeout(ssl, &onHttpSocketTimeout);
    http_context.setOnEnd(ssl, &onHttpSocketEnd);
    http_context.setOnConnectError(ssl, &onHttpSocketConnectError);

    websocket_context = try http_context.createChildContext(allocator, ssl, HttpContext);
    defer websocket_context.deinit(allocator);

    websocket_context.setOnOpen(ssl, &onWebSocketOpen);
    websocket_context.setOnData(ssl, &onWebSocketData);
    websocket_context.setOnWritable(ssl, &onWebSocketWritable);
    websocket_context.setOnClose(ssl, &onWebSocketClose);
    websocket_context.setOnTimeout(ssl, &onWebSocketTimeout);
    websocket_context.setOnEnd(ssl, &onWebSocketEnd);
    websocket_context.setOnConnectError(ssl, &onWebSocketConnectError);

    listen_socket = http_context.listenUnix(allocator, ssl, "hammer_test.sock", 0, HttpSocket) catch |err| {
        std.debug.print("Cannot listen to hammer_test.sock!\n", .{});
        return err;
    };

    listen_socket.s.setTimeout(ssl, 16);

    std.debug.print("Running hammer test over unix domain socket\n", .{});
    try state.printProgress(0);
    _ = try nextConnection(allocator);
    try loop.run(allocator);

    try state.printProgress(1);
    std.debug.print("\n", .{});

    if (opened_clients == 5000 and closed_clients == 5000 and opened_servers == 5000 and closed_servers == 5000) {
        std.debug.print("ALL GOOD\n", .{});
        return;
    } else {
        std.debug.print("MISMATCHING! FAILED!\n", .{});
        return;
    }
}
