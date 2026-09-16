const build_opts = @import("build_opts");
const constants = @import("constants.zig");
const std = @import("std");

const InternalCallback = @import("../../internal_callback.zig");
const Loop = @import("loop.zig");
const Poll = @import("poll.zig");

pub fn createAsync(allocator: std.mem.Allocator, io: std.Io, loop: *Loop, fallthrough: bool, comptime MaybeT: ?type) !*InternalCallback {
    if (build_opts.event_backend == .epoll) {
        const cb = try InternalCallback.init(allocator, io, loop, MaybeT);
        errdefer cb.deinit(allocator);
        try cb.p.create(allocator, io, loop, fallthrough, null);
        cb.p.init(@intCast(std.os.linux.eventfd(0, std.os.linux.EFD.NONBLOCK | std.os.linux.EFD.CLOEXEC)), .callback);
        cb.expects_loop = true;
        return cb;
    } else {
        const cb = try InternalCallback.init(allocator, io, loop, MaybeT);
        errdefer cb.deinit(allocator);
        cb.p.state.poll_type = .polling_in;
        cb.expects_loop = true;
        cb.p.setType(.callback);
        if (!fallthrough) loop.polls_count += 1;
        return cb;
    }
}

pub fn asyncSet(a: *InternalCallback, cb: *const fn (std.mem.Allocator, std.Io, *InternalCallback) anyerror!void) void {
    a.cb = cb;
    if (build_opts.event_backend == .epoll) a.p.start(a.loop, constants.socket_readable);
}

pub fn asyncWakeup(a: *InternalCallback) void {
    if (build_opts.event_backend == .epoll) {
        const one: u64 = 1;
        _ = std.os.linux.write(a.p.fd(), std.mem.asBytes(&one).ptr, @sizeOf(u64));
    } else {
        const event: std.posix.Kevent = .{
            .ident = @intFromPtr(&a.p),
            .filter = std.c.EVFILT.USER,
            .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
            .fflags = std.c.NOTE.TRIGGER,
            .data = 0,
            .udata = @intFromPtr(&a.p),
        };
        _ = std.c.kevent(a.loop.fd, &.{event}, 1, &.{}, 0, null);
    }
}

pub fn asyncClose(allocator: std.mem.Allocator, a: *InternalCallback) void {
    if (build_opts.event_backend == .epoll) {
        a.p.stop(a.loop);
        _ = std.os.linux.close(a.p.fd());
    } else {
        const event: std.posix.Kevent = .{
            .ident = @intFromPtr(&a.p),
            .filter = std.c.EVFILT.USER,
            .flags = std.c.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = @intFromPtr(&a.p),
        };
        _ = std.c.kevent(a.loop.fd, &.{event}, 1, &.{}, 0, null);
    }
    a.deinit(allocator);
}
