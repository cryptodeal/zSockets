const build_opts = @import("build_opts");

fn PollT(comptime opts: @TypeOf(build_opts)) type {
    if (opts.USE_IO_URING) @compileError("IO_URING event loop is not yet implemented");
    if (opts.USE_EPOLL or opts.USE_KQUEUE) return @import("events/epoll_kqueue.zig").Poll;
    if (opts.USE_LIBUV) @compileError("libuv event loop is not yet implemented");
    if (opts.USE_GCD) @compileError("GCD event loop is not yet implemented");
    if (opts.USE_ASIO) return @import("events/asio.zig").Poll;
    unreachable; // build.zig ensures that one is selected
}

pub const Poll = struct {};
