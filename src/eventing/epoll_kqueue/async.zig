const build_opts = @import("build_opts");
const constants = @import("constants.zig");
const linux = @import("../../bsd/linux.zig");
const std = @import("std");

const InternalCallback = @import("../../internal_callback.zig");
const Loop = @import("loop.zig");
const Poll = @import("poll.zig");

pub fn createAsync(allocator: std.mem.Allocator, io: std.Io, loop: *Loop, fallthrough: bool, comptime ExtensionTypes: []const type) !*InternalCallback {
    const cb = try InternalCallback.init(allocator, io, loop, ExtensionTypes);
    errdefer cb.deinit(allocator);
    if (comptime build_opts.event_backend == .epoll) {
        try cb.p.create(allocator, io, loop, fallthrough, &.{});
        cb.p.init(@intCast(linux.eventfd(0, std.os.linux.EFD.NONBLOCK | std.os.linux.EFD.CLOEXEC)), .callback);
        cb.expects_loop = true;
        return cb;
    } else {
        cb.p.state.poll_type = .polling_in;
        cb.expects_loop = true;
        cb.p.setType(.callback);
        if (!fallthrough) loop.polls_count += 1;
        return cb;
    }
}

pub fn asyncSet(a: *InternalCallback, cb: *const fn (std.mem.Allocator, std.Io, *InternalCallback) anyerror!void) void {
    a.cb = cb;
    if (comptime build_opts.event_backend == .epoll) a.p.start(a.loop, constants.socket_readable);
}

pub fn asyncWakeup(a: *InternalCallback) void {
    if (comptime build_opts.event_backend == .epoll) {
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
    if (comptime build_opts.event_backend == .epoll) {
        a.p.stop(a.loop);
        _ = linux.close(a.p.fd());
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
