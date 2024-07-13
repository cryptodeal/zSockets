const build_opts = @import("build_opts");

pub const SOCKET_READABLE = switch (build_opts.event_loop_lib) {
    .io_uring => @compileError("IO_URING event loop is not yet implemented"),
    .epoll, .kqueue => @import("events/epoll_kqueue.zig").SOCKET_READABLE,
    .libuv => @compileError("libuv event loop is not yet implemented"),
    .gcd => @compileError("GCD event loop is not yet implemented"),
    .asio => @import("events/asio.zig").SOCKET_READABLE,
};

pub const SOCKET_WRITABLE = switch (build_opts.event_loop_lib) {
    .io_uring => @compileError("IO_URING event loop is not yet implemented"),
    .epoll, .kqueue => @import("events/epoll_kqueue.zig").SOCKET_WRITABLE,
    .libuv => @compileError("libuv event loop is not yet implemented"),
    .gcd => @compileError("GCD event loop is not yet implemented"),
    .asio => @import("events/asio.zig").SOCKET_WRITABLE,
};

pub const Poll = switch (build_opts.event_loop_lib) {
    .io_uring => @compileError("IO_URING event loop is not yet implemented"),
    .epoll, .kqueue => @import("events/epoll_kqueue.zig").Poll,
    .libuv => @compileError("libuv event loop is not yet implemented"),
    .gcd => @compileError("GCD event loop is not yet implemented"),
    .asio => @import("events/asio.zig").Poll,
};
