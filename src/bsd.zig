const builtin = @import("builtin");
const socket = @import("socket.zig");
const std = @import("std");

const SocketDescriptor = socket.SocketDescriptor;

// Emulate `sendmmsg`/`recvmmsg` on platform that don't support it.
pub fn bsdSendMmsg(fd: SocketDescriptor, msgvec: ?*anyopaque, vlen: usize, flags: u32) !void {
    _ = fd; // autofix
    _ = msgvec; // autofix
    _ = vlen; // autofix
    _ = flags; // autofix

}
