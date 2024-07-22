const build_opts = @import("build_opts");

const Extensions = @import("zsockets.zig").Extensions;

const LoopType = fn (comptime ssl: bool, comptime extensions: Extensions) type;

pub const Loop: LoopType = switch (build_opts.event_loop_lib) {
    .epoll, .kqueue => @import("events/epoll_kqueue.zig").Loop,
    else => |v| @compileError("Unsupported event loop library " ++ @tagName(v)),
};

const PollType = fn (comptime PollExt: type, comptime LoopT: type) type;

pub const PollT: PollType = switch (build_opts.event_loop_lib) {
    .epoll, .kqueue => @import("events/epoll_kqueue.zig").PollT,
    else => |v| @compileError("Unsupported event loop library " ++ @tagName(v)),
};
