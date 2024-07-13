const std = @import("std");
const zs = @import("zSockets");

const Allocator = std.mem.Allocator;

const ssl = false;

const EchoSocket = struct {
    backpressure: []u8,
};

const EchoCtx = struct {};

fn onWakeup(_: *zs.Loop) !void {} // stub

fn onPre(_: *zs.Loop) !void {} // stub
fn onPost(_: *zs.Loop) !void {} // stub

fn onEchoSocketWritable(allocator: Allocator, s: *zs.Socket) !*zs.Socket {
    const es: *EchoSocket = @ptrCast(@alignCast(s.getExt(ssl)));
    const written = try s.write(ssl, es.backpressure, false);
    if (written != es.backpressure.len) {
        const new_buffer = try allocator.alloc(u8, es.backpressure.len - written);
        @memcpy(new_buffer, es.backpressure[written..]);
        allocator.free(es.backpressure);
        es.backpressure = new_buffer;
    } else {
        allocator.free(es.backpressure);
        es.backpressure = &[_]u8{};
    }
    s.setTimeout(ssl, 30);
    return s;
}

fn onEchoSocketClose(allocator: Allocator, s: *zs.Socket, _: i32, _: ?*anyopaque) !*zs.Socket {
    const es: *EchoSocket = @ptrCast(@alignCast(s.getExt(ssl)));
    std.log.info("Client disconnected\n", .{});
    allocator.free(es.backpressure);
    return s;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const loop = try zs.Loop.init(allocator, null, &onWakeup, &onPre, &onPost, 0);
    // TODO(cryptodeal): implement `Loop.Deinit()`

    const options: zs.SocketCtxOpts = .{};

    const echo_context = try zs.SocketCtx.init(allocator, ssl, loop, @sizeOf(EchoCtx), options);
    _ = echo_context; // autofix

    // register event handlers

}
