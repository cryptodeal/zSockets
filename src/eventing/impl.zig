const build_opts = @import("build_opts");

pub const Loop = switch (build_opts.event_backend) {
    .epoll, .kqueue => @import("epoll_kqueue/loop.zig"),
    .gcd => @import("gcd/loop.zig"),
    .libuv => @import("libuv/loop.zig"),
    // TODO: implement other backends
    else => |tag| @compileError("Event Backend `" ++ @tagName(tag) ++ "` not implemented."),
};

pub const Poll = switch (build_opts.event_backend) {
    .epoll, .kqueue => @import("epoll_kqueue/poll.zig"),
    .gcd => @import("gcd/poll.zig"),
    .libuv => @import("libuv/poll.zig"),
    // TODO: implement other backends
    else => |tag| @compileError("Event Backend `" ++ @tagName(tag) ++ "` not implemented."),
};

pub const createTimer = switch (build_opts.event_backend) {
    .epoll, .kqueue => @import("epoll_kqueue/timer.zig").createTimer,
    .gcd => @import("gcd/timer.zig").createTimer,
    .libuv => @import("libuv/timer.zig").createTimer,
    // TODO: implement other backends
    else => |tag| @compileError("Event Backend `" ++ @tagName(tag) ++ "` not implemented."),
};

pub const getTimerExt = switch (build_opts.event_backend) {
    .epoll, .kqueue => @import("epoll_kqueue/timer.zig").getTimerExt,
    .gcd => @import("gcd/timer.zig").getTimerExt,
    .libuv => @import("libuv/timer.zig").getTimerExt,
    else => |tag| @compileError("Event Backend `" ++ @tagName(tag) ++ "` not implemented."),
};

pub const timerSet = switch (build_opts.event_backend) {
    .epoll, .kqueue => @import("epoll_kqueue/timer.zig").timerSet,
    .gcd => @import("gcd/timer.zig").timerSet,
    .libuv => @import("libuv/timer.zig").timerSet,
    // TODO: implement other backends
    else => |tag| @compileError("Event Backend `" ++ @tagName(tag) ++ "` not implemented."),
};

pub const timerClose = switch (build_opts.event_backend) {
    .epoll, .kqueue => @import("epoll_kqueue/timer.zig").timerClose,
    .gcd => @import("gcd/timer.zig").timerClose,
    .libuv => @import("libuv/timer.zig").timerClose,
    // TODO: implement other backends
    else => |tag| @compileError("Event Backend `" ++ @tagName(tag) ++ "` not implemented."),
};

pub const createAsync = switch (build_opts.event_backend) {
    .epoll, .kqueue => @import("epoll_kqueue/async.zig").createAsync,
    .gcd => @import("gcd/async.zig").createAsync,
    .libuv => @import("libuv/async.zig").createAsync,
    // TODO: implement other backends
    else => |tag| @compileError("Event Backend `" ++ @tagName(tag) ++ "` not implemented."),
};

pub const asyncSet = switch (build_opts.event_backend) {
    .epoll, .kqueue => @import("epoll_kqueue/async.zig").asyncSet,
    .gcd => @import("gcd/async.zig").asyncSet,
    .libuv => @import("libuv/async.zig").asyncSet,
    // TODO: implement other backends
    else => |tag| @compileError("Event Backend `" ++ @tagName(tag) ++ "` not implemented."),
};

pub const asyncWakeup = switch (build_opts.event_backend) {
    .epoll, .kqueue => @import("epoll_kqueue/async.zig").asyncWakeup,
    .gcd => @import("gcd/async.zig").asyncWakeup,
    .libuv => @import("libuv/async.zig").asyncWakeup,
    // TODO: implement other backends
    else => |tag| @compileError("Event Backend `" ++ @tagName(tag) ++ "` not implemented."),
};

pub const asyncClose = switch (build_opts.event_backend) {
    .epoll, .kqueue => @import("epoll_kqueue/async.zig").asyncClose,
    .gcd => @import("gcd/async.zig").asyncClose,
    .libuv => @import("libuv/async.zig").asyncClose,
    // TODO: implement other backends
    else => |tag| @compileError("Event Backend `" ++ @tagName(tag) ++ "` not implemented."),
};

pub const socket_readable = switch (build_opts.event_backend) {
    .epoll, .kqueue => @import("epoll_kqueue/constants.zig").socket_readable,
    .gcd => @import("gcd/constants.zig").socket_readable,
    .libuv => @import("libuv/constants.zig").socket_readable,
    // TODO: implement other backends
    else => |tag| @compileError("Event Backend `" ++ @tagName(tag) ++ "` not implemented."),
};

pub const socket_writable = switch (build_opts.event_backend) {
    .epoll, .kqueue => @import("epoll_kqueue/constants.zig").socket_writable,
    .gcd => @import("gcd/constants.zig").socket_writable,
    .libuv => @import("libuv/constants.zig").socket_writable,
    // TODO: implement other backends
    else => |tag| @compileError("Event Backend `" ++ @tagName(tag) ++ "` not implemented."),
};
