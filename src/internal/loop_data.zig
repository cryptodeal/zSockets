const std = @import("std");
const zs = @import("../zsockets.zig");

const Allocator = std.mem.Allocator;

sweep_timer: *zs.Timer,
wakeup_async: *zs.InternalAsync,
last_write_failed: bool,
head: ?*zs.Context,
iterator: ?*zs.Context,
recv_buf: []u8 = &[_]u8{},
ssl_data: ?*anyopaque,
pre_cb: *const fn (allocator: Allocator, loop: *zs.Loop) anyerror!void,
post_cb: *const fn (allocator: Allocator, loop: *zs.Loop) anyerror!void,
closed_head: ?*zs.Socket,
low_priority_head: ?*zs.Socket,
low_priority_budget: i32,
iteration_nr: i64,
