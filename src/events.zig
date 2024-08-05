const build_opts = @import("build_opts");
const std = @import("std");

pub const Loop = switch (build_opts.event_loop_lib) {
    .kqueue, .epoll => @import("events/epoll_kqueue/loop.zig").Loop,
    inline else => |tag| @compileError(std.fmt.comptimePrint("Unsupported event loop library: {s}", .{@tagName(tag)})),
};

pub const Poll = switch (build_opts.event_loop_lib) {
    .kqueue, .epoll => @import("events/epoll_kqueue/poll.zig").Poll,
    inline else => |tag| @compileError(std.fmt.comptimePrint("Unsupported event loop library: {s}", .{@tagName(tag)})),
};
