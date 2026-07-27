const argsParser = @import("args");
const std = @import("std");
const zs = @import("zSockets");

const Options = struct {
    // This declares long options for double hyphen
    host: [:0]const u8 = "127.0.0.1",
    port: u32 = 3000,
    connections: u32 = 1000,
    @"pipeline-factor": ?usize = null,
    @"with-body": ?bool = null,
};

const ssl = true;

const request_template = "GET / HTTP/1.1\r\nHost: localhost:3000\r\nUser-Agent: curl/7.68.0\r\nAccept: */*\r\n\r\n";
const request_template_post = "POST / HTTP/1.1\r\nHost: localhost:3000\r\nUser-Agent: curl/7.68.0\r\nAccept: */*\r\nContent-Length: 10\r\n\r\n{\"key\":13}";

var request: []u8 = undefined;
var host: [:0]const u8 = undefined;
var port: u32 = undefined;
var connections: usize = undefined;

var responses: usize = undefined;
var pipeline: usize = 1;
var is_post = false;

const HttpSocket = struct {
    offset: usize,
};

const EchoContext = struct {};

fn onWakeup(_: std.mem.Allocator, _: *zs.Loop) !void {}

fn onPre(_: std.mem.Allocator, _: *zs.Loop) !void {}

fn onPost(_: std.mem.Allocator, _: *zs.Loop) !void {}

fn onHttpSocketWritable(_: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    const http_socket = s.getExt(HttpSocket).?;
    http_socket.offset += s.write(ssl, request[http_socket.offset .. request.len - http_socket.offset], false);
    return s;
}

fn onHttpSocketClose(_: std.mem.Allocator, s: *zs.Socket, _: i32, _: ?*anyopaque) !*zs.Socket {
    return s;
}

fn onHttpSocketEnd(allocator: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    return s.close(allocator, ssl, 0, null);
}

fn onHttpSocketData(_: std.mem.Allocator, s: *zs.Socket, _: []u8) !*zs.Socket {
    const http_socket = s.getExt(HttpSocket).?;
    http_socket.offset = s.write(ssl, request, false);
    responses += 1;
    return s;
}

fn onHttpSocketOpen(allocator: std.mem.Allocator, s: *zs.Socket, _: bool, _: []u8) !*zs.Socket {
    const http_socket = s.getExt(HttpSocket).?;
    http_socket.offset = 0;
    _ = s.write(ssl, request, false);
    connections -= 1;
    if (connections != 0) {
        _ = try s.context.connect(allocator, ssl, host, port, null, 0, HttpSocket);
    } else {
        std.debug.print("Running benchmark now...\n", .{});
        s.setTimeout(ssl, zs.constants.timeout_granularity);
        s.setLongTimeout(ssl, 1);
    }
    return s;
}

fn onHttpSocketLongTimeout(_: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    std.debug.print("--- Minute mark ---\n", .{});
    s.setLongTimeout(ssl, 1);
    return s;
}

fn onHttpSocketTimeout(_: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    std.debug.print("Req/sec: {d}\n", .{@as(f32, @floatFromInt(pipeline)) * @as(f32, @floatFromInt(responses)) / zs.constants.timeout_granularity});
    responses = 0;
    s.setTimeout(ssl, zs.constants.timeout_granularity);
    return s;
}

fn onHttpSocketConnectError(_: std.mem.Allocator, s: *zs.Socket, _: i32) !*zs.Socket {
    std.debug.print("Cannot connect to server\n", .{});
    return s;
}

pub fn main(init: std.process.Init) !void {
    const args = try argsParser.parseForCurrentProcess(Options, init, .print);
    defer args.deinit();

    // var gpa = std.heap.DebugAllocator(.{}){};
    // defer std.debug.assert(gpa.deinit() == .ok);
    // const allocator = gpa.allocator();

    const allocator = std.heap.smp_allocator;

    if (args.options.@"pipeline-factor") |p| {
        std.debug.print("Using pipeline factor of {d}\n", .{p});
        pipeline = p;
    }
    var selected_request: []const u8 = request_template;
    if (args.options.@"with-body") |wp| {
        std.debug.print("Using post with body\n", .{});
        is_post = wp;
        selected_request = request_template_post;
    }

    request = try allocator.alloc(u8, pipeline * selected_request.len);
    defer allocator.free(request);
    std.debug.print("request size {d}\n", .{request.len});
    for (0..pipeline) |i| {
        @memcpy(request[i * selected_request.len .. i * selected_request.len + selected_request.len], selected_request);
    }
    port = args.options.port;
    host = args.options.host;
    connections = args.options.connections;

    const loop = try zs.Loop.init(allocator, null, &onWakeup, &onPre, &onPost, null);
    defer loop.deinit(allocator);

    // TODO: enable SSL and pass relevant options
    const options: zs.SocketContextOptions = .{
        .key_file_name = "/Users/cryptodeal/zSockets/misc/valid_server_key.pem",
        .cert_file_name = "/Users/cryptodeal/zSockets/misc/valid_server_crt.pem",
        .passphrase = "1234",
    };
    const http_context = try zs.SocketContext.init(allocator, ssl, loop, options, null);
    // TODO: implement `SocketContext.deinit`
    defer http_context.deinit(allocator);

    http_context.setOnOpen(ssl, &onHttpSocketOpen);
    http_context.setOnData(ssl, &onHttpSocketData);
    http_context.setOnWritable(ssl, &onHttpSocketWritable);
    http_context.setOnClose(ssl, &onHttpSocketClose);
    http_context.setOnTimeout(ssl, &onHttpSocketTimeout);
    http_context.setOnLongTimeout(ssl, &onHttpSocketLongTimeout);
    http_context.setOnEnd(ssl, &onHttpSocketEnd);
    http_context.setOnConnectError(ssl, &onHttpSocketConnectError);

    if (http_context.connect(allocator, ssl, host, port, null, 0, HttpSocket)) |_| {} else |err| {
        std.debug.print("Cannot connect to server\n", .{});
        return err;
    }

    try loop.run(allocator);
}
