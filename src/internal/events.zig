const build_opts = @import("build_opts");

pub const InternalAsync = anyopaque;

pub const Poll = switch (build_opts.event_loop_lib) {
    .io_uring => @compileError("IO_URING event loop is not yet implemented"),
    .epoll, .kqueue => @import("events/epoll_kqueue.zig").Poll,
    .libuv => @compileError("libuv event loop is not yet implemented"),
    .gcd => @compileError("GCD event loop is not yet implemented"),
    .asio => @import("events/asio.zig").Poll,
};
