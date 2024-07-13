const constants = @import("../constants.zig");
const context = @import("../context.zig");
const internal = @import("internal.zig");
const std = @import("std");

const Loop = @import("../loop.zig").Loop;

const Allocator = std.mem.Allocator;
const RECV_BUFFER_LENGTH = constants.RECV_BUFFER_LENGTH;
const RECV_BUFFER_PADDING = constants.RECV_BUFFER_PADDING;
const Socket = internal.Socket;
const SocketCtx = context.SocketCtx;
const Timer = internal.Timer;

pub const InternalLoopData = struct {
    sweep_timer: ?*Timer,
    wakeup_async: ?*anyopaque,
    last_write_failed: bool,
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
