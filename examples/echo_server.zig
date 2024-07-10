const std = @import("std");
const zs = @import("zSockets");

const EchoSocket = struct {
    backpressure: []u8,
};

const EchoCtx = struct {};

fn onWakeup(_: *zs.Loop) void {} // stub

fn onPre(_: *zs.Loop) void {} // stub
fn onPost(_: *zs.Loop) void {} // stub

// fn onEchoSocketWritable(s: zs.)

pub fn main() !void {
    std.debug.print("running demo", .{});
}
