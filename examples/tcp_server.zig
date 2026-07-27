const std = @import("std");
const zs = @import("zSockets");

fn onWakeup(_: std.mem.Allocator, _: *zs.Loop) !void {}

fn onPre(_: std.mem.Allocator, _: *zs.Loop) !void {}

fn onPost(_: std.mem.Allocator, _: *zs.Loop) !void {}

fn onHttpSocketWritable(_: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    return s;
}

fn onHttpSocketClose(_: std.mem.Allocator, s: *zs.Socket, _: i32, _: ?*anyopaque) !*zs.Socket {
    std.debug.print("Client disconnected\n", .{});
    return s;
}

fn onHttpSocketEnd(allocator: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    s.shutdown(false);
    return s.close(allocator, false, 0, null);
}

fn onHttpSocketData(_: std.mem.Allocator, s: *zs.Socket, _: []u8) !*zs.Socket {
    _ = s.write(false, "Hello short message!", false);
    return s;
}

fn onHttpSocketOpen(_: std.mem.Allocator, s: *zs.Socket, _: bool, _: []u8) !*zs.Socket {
    std.debug.print("Client connected\n", .{});
    return s;
}

fn onHttpSocketTimeout(_: std.mem.Allocator, s: *zs.Socket) !*zs.Socket {
    return s;
}

pub fn main(_: std.process.Init) !void {
    // var gpa = std.heap.DebugAllocator(.{}){};
    // defer std.debug.assert(gpa.deinit() == .ok);
    // const allocator = gpa.allocator();

    const allocator = std.heap.smp_allocator;

    const loop = try zs.Loop.init(allocator, null, &onWakeup, &onPre, &onPost, null);
    defer loop.deinit(allocator);

    // TODO: enable SSL and pass relevant options
    const options: zs.SocketContextOptions = .{};
    const http_context = try zs.SocketContext.init(allocator, false, loop, options, null);
    // TODO: implement `SocketContext.deinit`
    defer http_context.deinit(allocator);

    http_context.setOnOpen(false, &onHttpSocketOpen);
    http_context.setOnData(false, &onHttpSocketData);
    http_context.setOnWritable(false, &onHttpSocketWritable);
    http_context.setOnClose(false, &onHttpSocketClose);
    http_context.setOnTimeout(false, &onHttpSocketTimeout);
    http_context.setOnEnd(false, &onHttpSocketEnd);

    if (http_context.listen(allocator, false, null, 3000, 0, null)) |_| {
        std.debug.print("Listening on port 3000...\n", .{});
        try loop.run(allocator);
    } else |_| {
        std.debug.print("Failed to listen!\n", .{});
    }
}
