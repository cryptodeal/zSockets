//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
// const build_opts = @import("build_opts");

pub const createTimer = @import("eventing/impl.zig").createTimer;
pub const getTimerExt = @import("eventing/impl.zig").getTimerExt;
pub const timerSet = @import("eventing/impl.zig").timerSet;
pub const timerClose = @import("eventing/impl.zig").timerClose;

pub const loop = @import("loop.zig");
pub const Loop = @import("eventing/impl.zig").Loop;
pub const Poll = @import("eventing/impl.zig").Poll;
pub const Socket = @import("socket.zig");
pub const SocketContext = @import("socket_context.zig");
pub const SocketContextOptions = @import("socket_context_options.zig");
pub const InternalCallback = @import("internal_callback.zig");
pub const ListenSocket = @import("listen_socket.zig");
pub const Timer = @import("internal/internal.zig").Timer;
pub const quic = @import("quic.zig");
pub const udp = @import("udp.zig");

pub const constants = @import("internal/constants.zig");
// TODO: maybe expose via `quic` namespace and codegen?
// pub const lsquic = switch (build_opts.with_quic) {
//     true => @import("lsquic"),
//     else => {},
// };

test "SNI Tree functionality" {
    std.testing.refAllDecls(@import("crypto/sni_tree.zig"));
}
