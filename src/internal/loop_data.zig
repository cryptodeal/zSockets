const constants = @import("../constants.zig");
const internal = @import("internal.zig");
const std = @import("std");

const Loop = @import("../loop.zig").Loop;

const Allocator = std.mem.Allocator;
const RECV_BUFFER_LENGTH = constants.RECV_BUFFER_LENGTH;
const RECV_BUFFER_PADDING = constants.RECV_BUFFER_PADDING;
const Socket = internal.Socket;
const SocketCtx = internal.SocketCtx;
const Timer = internal.Timer;

pub const InternalLoopData = struct {
    sweep_timer: ?*Timer,
    wakeup_async: ?*anyopaque,
    last_write_failed: i32,
    head: ?*SocketCtx,
    iterator: ?*SocketCtx,
    recv_buf: []u8,
    ssl_data: ?*anyopaque,
    pre_cb: *const fn (loop: *Loop) anyerror!void,
    post_cb: *const fn (loop: *Loop) anyerror!void,
    closed_head: ?*Socket,
    low_prio_head: ?*Socket,
    low_prio_budget: i32,
    //  We do not care if this flips or not, it doesn't matter
    iteration_nr: i64,
};

pub fn internalLoopDataInit(
    allocator: Allocator,
    loop: *Loop,
    wakeup_cb: *const fn (loop: *Loop) anyerror!void,
    pre_cb: *const fn (loop: *Loop) anyerror!void,
    post_cb: *const fn (loop: *Loop) anyerror!void,
) !void {
    _ = wakeup_cb; // autofix
    loop.data.sweep_timer = try loop.createTimer(allocator, true, 0);
    // TODO: errdefer close file handle
    loop.data.recv_buf = try allocator.alloc(u8, RECV_BUFFER_LENGTH + RECV_BUFFER_PADDING * 2);
    errdefer allocator.free(loop.data.recv_buf);
    loop.data.ssl_data = null;
    loop.data.head = null;
    loop.data.iterator = null;
    loop.data.closed_head = null;
    loop.data.low_prio_head = null;
    loop.data.low_prio_budget = 0;
    loop.data.pre_cb = pre_cb;
    loop.data.post_cb = post_cb;
    loop.data.last_write_failed = 0;
    loop.data.iteration_nr = 0;
}
