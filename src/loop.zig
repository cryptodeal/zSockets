const build_opts = @import("build_opts");

const SocketCtx = @import("context.zig").SocketCtx;

pub const Loop = switch (build_opts.event_loop_lib) {
    .io_uring => @compileError("IO_URING event loop is not yet implemented"),
    .epoll, .kqueue => @import("internal/events/epoll_kqueue.zig").Loop,
    .libuv => @compileError("libuv event loop is not yet implemented"),
    .gcd => @compileError("GCD event loop is not yet implemented"),
    .asio => @import("internal/events/asio.zig").Loop,
};

pub fn internalLoopLink(loop: *Loop, ctx: *SocketCtx) void {
    ctx.next = loop.data.head;
    ctx.prev = null;
    if (loop.data.head) |head| {
        head.prev = ctx;
    }
    loop.data.head = ctx;
}
