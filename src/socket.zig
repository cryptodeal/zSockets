const build_opts = @import("build_opts");
const builtin = @import("builtin");
const internal = @import("internal/internal.zig");
const ssl = @import("crypto/ssl.zig");
const std = @import("std");

// TODO: type needs switch based on build opts?
pub const Socket = internal.Socket;

pub fn socketLocalPort(_: i32, s: *Socket) i32 {
    _ = s; // autofix

}
