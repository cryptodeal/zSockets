const builtin = @import("builtin");
const std = @import("std");
const libuv = if (builtin.os.tag.isDarwin()) @import("darwin_libuv.zig") else @import("libuv");
const Poll = @import("poll.zig");
const Timer = @import("../../internal/internal.zig").Timer;
const InternalCallback = @import("../../internal_callback.zig");
const Loop = @import("loop.zig");
const UvWrapper = @import("utils.zig").UvWrapper;

const UvTimer = struct {};

fn timerCb(t: ?*libuv.uv_timer_t) callconv(.c) void {
    const cb: *InternalCallback = @ptrCast(@alignCast(t.?.data));
    cb.cb.?(cb.allocator, cb.io, cb) catch |err| {
        std.debug.print("timerCb Error: {s}\n", .{@errorName(err)});
        std.debug.dumpCurrentStackTrace(.{});
    };
}

fn closeCbFree(t: ?*libuv.uv_handle_t) callconv(.c) void {
    const cb: *InternalCallback = @ptrCast(@alignCast(t.?.data));
    const uv_timer: ?*libuv.uv_timer_t = @ptrCast(@alignCast(cb.server_data));
    cb.allocator.destroy(uv_timer.?);
    cb.deinit(cb.allocator);
    // TODO: probably need to free timer here as well
}

pub fn createTimer(allocator: std.mem.Allocator, io: std.Io, loop: *Loop, fallthrough: bool, comptime Ext: ?type) !*Timer {
    const cb = try InternalCallback.init(allocator, io, loop, Ext);
    cb.p.callback_payload = try Poll.CallbackPayload.init(allocator, &cb.p);
    const uv_timer = try allocator.create(libuv.uv_timer_t);
    _ = libuv.uv_timer_init(loop.uv_loop, uv_timer);
    uv_timer.data = cb;
    cb.server_data = uv_timer;
    if (fallthrough) {
        libuv.uv_unref(@ptrCast(@alignCast(uv_timer)));
    }
    return cb;
}

pub fn getTimerExt(t: *Timer, comptime T: type) ?*T {
    return @as(*InternalCallback, @ptrCast(@alignCast(t))).getExt(T);
}

pub fn timerSet(t: *Timer, cb: ?*const fn (std.mem.Allocator, std.Io, *Timer) anyerror!void, ms: i64, repeat_ms: i64) void {
    const internal_cb: *InternalCallback = @ptrCast(@alignCast(t));
    internal_cb.cb = @ptrCast(@alignCast(cb));
    const uv_timer: ?*libuv.uv_timer_t = @ptrCast(@alignCast(internal_cb.server_data));
    if (ms == 0) {
        _ = libuv.uv_timer_stop(uv_timer);
    } else {
        _ = libuv.uv_timer_start(uv_timer, &timerCb, @intCast(ms), @intCast(repeat_ms));
    }
}

pub fn timerClose(_: std.mem.Allocator, timer: *Timer) void {
    const internal_cb: *InternalCallback = @ptrCast(@alignCast(timer));
    const uv_timer: ?*libuv.uv_timer_t = @ptrCast(@alignCast(internal_cb.server_data));
    libuv.uv_ref(@ptrCast(@alignCast(uv_timer)));
    _ = libuv.uv_timer_stop(uv_timer);
    uv_timer.?.data = internal_cb;
    libuv.uv_close(@ptrCast(@alignCast(uv_timer)), &closeCbFree);
}
