const std = @import("std");
const zs = @import("zSockets");

var context: *zs.quic.SocketContext = undefined;

fn onWakeup(_: std.mem.Allocator, _: *zs.Loop) !void {}

fn onPre(_: std.mem.Allocator, _: *zs.Loop) !void {}

fn onPost(_: std.mem.Allocator, _: *zs.Loop) !void {}

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
    try context.setHeader(0, ":status", "200");
    try context.sendHeaders(s, 1, true);
    const data: []const u8 = "Hello quic!";
    _ = zs.quic.streamWrite(s, @constCast(data));
    zs.quic.streamShutdown(s);
}

fn onStreamData(_: std.mem.Allocator, _: ?*anyopaque, data: []u8) !void {
    std.debug.print("Body length is: {d}\n", .{data.len});
}

fn onStreamWritable(_: std.mem.Allocator, _: ?*anyopaque) !void {}

fn onStreamClose(_: std.mem.Allocator, _: ?*anyopaque) !void {}

fn onOpen(_: std.mem.Allocator, _: *zs.quic.Socket, _: bool) !void {
    std.debug.print("Connection established!\n", .{});
}

fn onStreamOpen(_: std.mem.Allocator, _: ?*anyopaque, _: bool) !void {
    // std.debug.print("Stream opened!\n", .{});
}

fn onClose(_: std.mem.Allocator, _: *zs.quic.Socket) !void {
    std.debug.print("Disconnected!\n", .{});
}

pub fn main(_: std.process.Init) !void {
    // var gpa = std.heap.DebugAllocator(.{}){};
    // defer std.debug.assert(gpa.deinit() == .ok);
    // const allocator = gpa.allocator();

    const allocator = std.heap.smp_allocator;

    const loop = try zs.Loop.init(allocator, null, &onWakeup, &onPre, &onPost, null);
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

    _ = try context.listen(allocator, "::1", 9004, null);
    // defer listen_socket.deinit(allocator);

    // Run the event loop
    try loop.run(allocator);
    std.debug.print("Falling through!\n", .{});
}
