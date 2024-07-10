const builtin = @import("builtin");
const internal = @import("internal/internal.zig");
const std = @import("std");

pub const SocketDescriptor = std.posix.socket_t;

// TODO: type needs switch based on build opts?
pub const Socket = internal.Socket;

pub fn socketLocalPort(_: i32, s: *Socket) i32 {
    _ = s; // autofix

}
