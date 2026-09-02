const build_opts = @import("build_opts");
const constants = @import("constants.zig");
const builtin = @import("builtin");
const std = @import("std");
const Timer = @import("../../internal/internal.zig").Timer;

const InternalCallback = @import("../../internal_callback.zig");
const Loop = @import("loop.zig");
const Poll = @import("poll.zig");

pub fn createTimer(allocator: std.mem.Allocator, loop: *Loop, fallthrough: bool, comptime MaybeT: ?type) !*Timer {
    const cb = try InternalCallback.init(allocator, loop, MaybeT);
    errdefer cb.deinit(allocator);
    if (build_opts.event_backend == .epoll) {
        try cb.p.create(allocator, loop, fallthrough, null);
        const timer_fd = std.os.linux.timerfd_create(std.os.linux.TIMERFD_CLOCK.REALTIME, .{ .NONBLOCK = true, .CLOEXEC = true });
        cb.p.init(@intCast(timer_fd), .callback);
        return cb;
    } else {
        cb.p.state.poll_type = .polling_in;
        cb.p.setType(.callback);
        if (!fallthrough) loop.polls_count += 1;
        return cb;
    }
}

pub fn getTimerExt(t: *Timer, comptime T: type) ?*T {
    return @as(*InternalCallback, @ptrCast(@alignCast(t))).getExt(T);
}

pub fn timerSet(t: *Timer, cb: ?*const fn (std.mem.Allocator, *Timer) anyerror!void, ms: i64, repeat_ms: i64) void {
    const internal_cb: *InternalCallback = @ptrCast(@alignCast(t));
    internal_cb.cb = @ptrCast(@alignCast(cb));
    if (build_opts.event_backend == .epoll) {
        const timer_spec: std.os.linux.itimerspec = .{
            .it_interval = .{ .sec = @divTrunc(repeat_ms, 1000), .nsec = @rem(repeat_ms, 1000) * 1000000 },
            .it_value = .{ .sec = @divTrunc(ms, 1000), .nsec = @rem(ms, 1000) * 1000000 },
        };
        _ = std.os.linux.timerfd_settime(internal_cb.p.fd(), @bitCast(@as(u32, 0)), &timer_spec, null);
        internal_cb.p.start(internal_cb.loop, constants.socket_readable);
    } else {
        const event: std.posix.Kevent = .{
            .ident = @intFromPtr(&internal_cb.p),
            .filter = std.c.EVFILT.TIMER,
            .flags = std.c.EV.ADD | if (repeat_ms != 0) 0 else @as(@FieldType(std.posix.Kevent, "flags"), std.c.EV.ONESHOT),
            .fflags = 0,
            .data = ms,
            .udata = @intFromPtr(&internal_cb.p),
        };
        _ = std.c.kevent(internal_cb.loop.fd, &.{event}, 1, &.{}, 0, null);
    }
}

pub fn timerClose(allocator: std.mem.Allocator, timer: *Timer) void {
    const internal_cb: *InternalCallback = @ptrCast(@alignCast(timer));
    if (build_opts.event_backend == .epoll) {
        internal_cb.p.stop(internal_cb.loop);
        _ = std.c.close(internal_cb.p.fd());
    } else {
        const event: std.posix.Kevent = .{
            .ident = @intFromPtr(&internal_cb.p),
            .filter = std.c.EVFILT.TIMER,
            .flags = std.c.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = @intFromPtr(&internal_cb.p),
        };
        _ = std.c.kevent(internal_cb.loop.fd, &.{event}, 1, &.{}, 0, null);
    }
    internal_cb.deinit(allocator);
}
