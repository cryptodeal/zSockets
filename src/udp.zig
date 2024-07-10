const bsd = @import("internal/network/bsd.zig");
const builtin = @import("builtin");
const socket = @import("socket.zig");
const std = @import("std");

const UDP_MAX_NUM = bsd.LIBUS_UDP_MAX_NUM;

pub const SocketDescriptor = socket.SocketDescriptor;

const UdpPacketBuffer = struct {
    buf: [UDP_MAX_NUM][]u8,
    addr: [UDP_MAX_NUM]std.c.sockaddr.storage,
};

const LinuxUdpPacketBuffer = struct {
    msgvec: [UDP_MAX_NUM]MmsgHdr,
    iov: [UDP_MAX_NUM]std.c.iovec,
    addr: [UDP_MAX_NUM]std.c.sockaddr.storage,
    control: [UDP_MAX_NUM][256]u8,
};

pub const InternalUdpPacketBuffer = if (builtin.os.tag.isDarwin() or builtin.os.tag == .windows) UdpPacketBuffer else LinuxUdpPacketBuffer;

pub const UdpSocket = struct {
    ref: ?*anyopaque,
};

pub const MmsgHdr = struct {
    msg_hdr: std.c.msghdr,
    msg_len: usize,
};
