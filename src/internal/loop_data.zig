const build_opts = @import("build_opts");
const openssl = @import("../crypto/openssl.zig");
const constants = @import("constants.zig");
const std = @import("std");
const SocketContext = @import("../socket_context.zig");
const Loop = @import("../eventing/impl.zig").Loop;
const createAsync = @import("../eventing/impl.zig").createAsync;
const asyncClose = @import("../eventing/impl.zig").asyncClose;
const createTimer = @import("../eventing/impl.zig").createTimer;
const timerClose = @import("../eventing/impl.zig").timerClose;
const asyncSet = @import("../eventing/impl.zig").asyncSet;
const Timer = @import("internal.zig").Timer;

const Socket = @import("../socket.zig");
const InternalCallback = @import("../internal_callback.zig");

const Self = @This();

sweep_timer: ?*Timer = null,
wakeup_async: ?*InternalCallback = null,
last_write_failed: bool = false,
head: ?*SocketContext = null,
iterator: ?*SocketContext = null,
recv_buf: []u8,
ssl_data: ?*anyopaque = null,
pre_cb: *const fn (std.mem.Allocator, std.Io, *Loop) anyerror!void,
post_cb: *const fn (std.mem.Allocator, std.Io, *Loop) anyerror!void,
closed_head: ?*Socket = null,
low_priority_head: ?*Socket = null,
low_priority_budget: i32 = 0,
iteration_count: i64 = 0,

pub fn init(allocator: std.mem.Allocator, io: std.Io, loop: *Loop, wakeup_cb: *const fn (std.mem.Allocator, std.Io, *Loop) anyerror!void, pre_cb: *const fn (std.mem.Allocator, std.Io, *Loop) anyerror!void, post_cb: *const fn (std.mem.Allocator, std.Io, *Loop) anyerror!void) !Self {
    const self: Self = .{
        .sweep_timer = try createTimer(allocator, io, loop, true, null),
        .recv_buf = try allocator.alloc(u8, constants.recv_buffer_length + constants.recv_buffer_padding * 2),
        .pre_cb = pre_cb,
        .post_cb = post_cb,
        .wakeup_async = try createAsync(allocator, io, loop, true, null),
    };
    asyncSet(self.wakeup_async.?, @ptrCast(@alignCast(wakeup_cb)));
    return self;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    if (build_opts.ssl_impl != .no_ssl) {
        if (@as(?*openssl.LoopSslData, @ptrCast(@alignCast(self.ssl_data)))) |ssl_data| {
            ssl_data.deinit(allocator);
            self.ssl_data = null;
        }
    }
    allocator.free(self.recv_buf);
    if (self.sweep_timer) |sweep_timer| timerClose(allocator, sweep_timer);
    if (self.wakeup_async) |wakeup_async| asyncClose(allocator, wakeup_async);
}
