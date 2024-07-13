const builtin = @import("builtin");
const internal = @import("internal/internal.zig");
const std = @import("std");

const SocketDescriptor = internal.SocketDescriptor;

// Emulate `sendmmsg`/`recvmmsg` on platform that don't support it.
pub fn bsdSendMmsg(fd: SocketDescriptor, msgvec: ?*anyopaque, vlen: usize, flags: u32) !void {
    _ = fd; // autofix
    _ = msgvec; // autofix
    _ = vlen; // autofix
    _ = flags; // autofix

}

pub fn bsdSend(fd: SocketDescriptor, buf: []const u8, msg_more: bool) !usize {
    return switch (builtin.os.tag) {
        .linux => std.posix.send(fd, buf, (@intFromBool(msg_more) * std.posix.MSG.MORE) | std.posix.MSG.NOSIGNAL),
        else => std.posix.send(fd, buf, 0),
    };
}

pub fn bsdSocketFlush(fd: SocketDescriptor) !void {
    try std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, std.os.linux.TCP.CORK, &.{0});
}
