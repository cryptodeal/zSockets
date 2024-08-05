const build_opts = @import("build_opts");
const std = @import("std");

pub const SOCKET_READABLE = switch (build_opts.event_loop_lib) {
    .epoll => std.c.EPOLL.IN,
    else => 1,
};

pub const SOCKET_WRITABLE = switch (build_opts.event_loop_lib) {
    .epoll => std.c.EPOLL.OUT,
    else => 2,
};
