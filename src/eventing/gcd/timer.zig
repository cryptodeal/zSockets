const std = @import("std");
const Loop = @import("loop.zig");
const Timer = @import("../../internal/internal.zig").Timer;
const InternalCallback = @import("../../internal_callback.zig");

fn gcdTimerHandler(t: ?*anyopaque) callconv(.c) void {
    const internal_cb: *InternalCallback = @ptrCast(@alignCast(t));
    internal_cb.cb.?(internal_cb.allocator, internal_cb.io, internal_cb) catch |err| {
        std.debug.print("timerCb Error: {s}\n", .{@errorName(err)});
        std.debug.dumpCurrentStackTrace(.{});
    };
}

pub fn createTimer(allocator: std.mem.Allocator, io: std.Io, loop: *Loop, fallthrough: bool, comptime Ext: ?type) !*Timer {
    _ = fallthrough;
    const cb = try InternalCallback.init(allocator, io, loop, Ext);
    const gcd_timer = std.c.dispatch.source_create(std.c.dispatch.SOURCE_TYPE_TIMER, 0, @bitCast(@as(usize, 0)), std.c.dispatch.get_main_queue());
    cb.server_data = gcd_timer.?;
    std.c.dispatch.source_set_event_handler_f(gcd_timer.?, &gcdTimerHandler);
    std.c.dispatch.set_context(gcd_timer.?.as_object(), cb);
    // if (fallthrough) {}
    return cb;
}

pub fn getTimerExt(t: *Timer, comptime T: type) ?*T {
    return @as(*InternalCallback, @ptrCast(@alignCast(t))).getExt(T);
}

pub fn timerSet(t: *Timer, cb: ?*const fn (std.mem.Allocator, std.Io, *Timer) anyerror!void, ms: i64, _: i64) void {
    const internal_cb: *InternalCallback = @ptrCast(@alignCast(t));
    internal_cb.cb = @ptrCast(@alignCast(cb));
    const gcd_timer: std.c.dispatch.source_t = @ptrCast(@alignCast(internal_cb.server_data));
    const nanos = @as(u64, @intCast(ms)) * 1000000;
    std.c.dispatch.source_set_timer(gcd_timer, @enumFromInt(0), nanos, 0);
    std.c.dispatch.activate(gcd_timer.as_object());
}

pub fn timerClose(_: std.mem.Allocator, _: *Timer) void {}
