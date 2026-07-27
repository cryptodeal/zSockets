const builtin = @import("builtin");
const c = @import("c.zig");
const EnumError = @import("../internal/internal.zig").EnumError;
const cmsg = @import("cmsg.zig");
const constants = @import("constants.zig");
const std = @import("std");

pub const udp_max_size = constants.udp_max_size;
pub const udp_max_num = constants.udp_max_num;
pub const PacketBuffer = switch (builtin.os.tag) {
    .windows => @import("packet_buffer/windows.zig"),
    else => @import("packet_buffer/generic.zig"),
};

pub const Addr = extern struct {
    mem: std.posix.sockaddr.storage,
    len: std.posix.socklen_t,
    ip: [*c]u8,
    ip_length: c_int,
    port: c_int,
};

pub fn sendmmsg(
    fd: std.c.fd_t,
    msgvec: switch (builtin.os.tag) {
        .windows => *PacketBuffer,
        else => [*]std.c.mmsghdr,
    },
    vlen: usize,
    flags: u32,
) !usize {
    switch (builtin.os.tag) {
        .windows => {
            for (0..udp_max_num) |i| {
                const ret = std.c.sendto(fd, msgvec.buf[i], msgvec.len[i], flags, @ptrCast(@alignCast(&msgvec.addr[i])), @sizeOf(std.posix.sockaddr.in));
                if (ret == -1) {
                    return i;
                }
            }
            return udp_max_num;
        },
        .driverkit,
        .ios,
        .maccatalyst,
        .macos,
        .tvos,
        .visionos,
        .watchos,
        => {
            // TODO: leverage `sendmsg_x` private api
            if (c.supportSendRecvMsgX()) {
                while (true) {
                    const ret = c.sendmsg_x(fd, msgvec, @intCast(vlen), @intCast(flags));
                    if (ret >= 0) return @intCast(ret);
                    const err = std.c.errno(ret);
                    if (err == .MSGSIZE) break;
                    if (err != .INTR) {
                        // std.debug.print("errno: {s}\n", .{@tagName(std.c.errno(ret))});
                        return error.SendMmsgX;
                    }
                }
            }
            const hdrs: [*]extern struct { msghdr: std.c.msghdr_const, len: u32 } = @ptrCast(@alignCast(msgvec));
            for (0..vlen) |i| {
                const ret = std.c.sendmsg(fd, &hdrs[i].msghdr, flags);
                if (ret == -1) {
                    if (i != 0) {
                        return i;
                    } else {
                        // std.debug.print("errno: {s}\n", .{@tagName(std.c.errno(ret))});
                        return error.SendMmsg;
                    }
                } else {
                    hdrs[i].len = @intCast(ret);
                }
            }
            return vlen;
        },
        else => return std.os.linux.sendmmsg(fd, msgvec, vlen, flags | std.c.MSG.NOSIGNAL),
    }
}

pub fn recvmmsg(
    fd: std.posix.fd_t,
    msgvec: switch (builtin.os.tag) {
        .windows => *PacketBuffer,
        else => [*]std.c.mmsghdr,
    },
    vlen: usize,
    flags: u32,
    _: ?*anyopaque,
) !usize {
    switch (builtin.os.tag) {
        .windows => {
            for (0..udp_max_num) |i| {
                const addr_len = @sizeOf(std.c.sockaddr.storage);
                const ret = std.c.recvfrom(fd, msgvec.buf[i], flags, @as(?*std.c.sockaddr, @ptrCast(@alignCast(&msgvec.addr[i]))), &addr_len);
                if (ret == -1) {
                    return i;
                }
                msgvec.len[i] = @intCast(ret);
            }
            return udp_max_num;
        },
        .driverkit,
        .ios,
        .maccatalyst,
        .macos,
        .tvos,
        .visionos,
        .watchos,
        => {
            for (0..vlen) |i| {
                msgvec[i].hdr.controllen = 256;
            }
            // TODO: leverage `recvmsg_x` private api
            if (c.supportSendRecvMsgX()) {
                while (true) {
                    const ret = c.recvmsg_x(fd, msgvec, @intCast(vlen), @intCast(flags));
                    if (ret >= 0) return @intCast(ret);
                    if (std.c.errno(ret) != .INTR) return error.RecvMmsgX;
                }
            }
            for (0..vlen) |i| {
                const ret = std.c.recvmsg(fd, &msgvec[i].hdr, flags);
                if (ret == -1) {
                    return i;
                }
                msgvec[i].len = @intCast(ret);
            }
            return vlen;
        },
        else => {
            for (0..vlen) |i| {
                msgvec[i].hdr.controllen = 256;
            }
            return std.os.linux.recvmmsg(fd, msgvec, vlen, @intCast(flags), null);
        },
    }
}

pub fn udpPacketBufferLocalIp(
    msgvec: switch (builtin.os.tag) {
        .windows => *PacketBuffer,
        else => [*]std.c.mmsghdr,
    },
    index: usize,
    ip: []u8,
) ![]u8 {
    switch (builtin.os.tag) {
        .windows => return &.{},
        else => {
            // TODO: implement for darwin
            if (builtin.os.tag.isDarwin()) return &.{};
            const mh: *std.c.msghdr = &msgvec[index].hdr;
            var maybe_cmsghdr = cmsg.firsthdr(mh);
            while (maybe_cmsghdr) |cmsghdr| {
                if (cmsghdr.level == std.c.IPPROTO.IP and cmsghdr.type == c.IP.PKTINFO) {
                    if (ip.len < 4) return error.NoSpaceLeft;
                    const pi: *std.c.in_pktinfo = @ptrCast(@alignCast(cmsg.data(cmsghdr)));
                    @memcpy(ip[0..4], std.mem.asBytes(&pi.addr)[0..4]);
                    return ip[0..4];
                }
                if (cmsghdr.level == std.c.IPPROTO.IP and cmsghdr.type == c.IP.RECVDSTADDR) {
                    const addr: [*]u8 = @ptrCast(@alignCast(cmsg.data(cmsghdr)));
                    @memcpy(ip[0..4], addr[0..4]);
                    return ip[0..4];
                }
                if (cmsghdr.level == std.c.IPPROTO.IPV6 and cmsghdr.type == c.IPV6.PKTINFO) {
                    const pi6: *std.c.in6_pktinfo = @ptrCast(@alignCast(cmsg.data(cmsghdr)));
                    @memcpy(ip[0..16], pi6.addr[0..16]);
                    return ip[0..16];
                }
                maybe_cmsghdr = cmsg.nexthdr(mh, cmsghdr);
            }
            return &.{};
        },
    }
}

pub fn udpPacketBufferPeer(
    msgvec: switch (builtin.os.tag) {
        .windows => *PacketBuffer,
        else => [*]std.c.mmsghdr,
    },
    index: usize,
) [*]u8 {
    switch (builtin.os.tag) {
        .windows => return @ptrCast(@alignCast(&msgvec.addr[index])),
        else => return @ptrCast(@alignCast(msgvec[index].hdr.name)),
    }
}

pub fn udpPacketBufferPayload(
    msgvec: switch (builtin.os.tag) {
        .windows => *PacketBuffer,
        else => [*]std.c.mmsghdr,
    },
    index: usize,
) []u8 {
    switch (builtin.os.tag) {
        .windows => return &msgvec.buf[index][0..msgvec.len[index]],
        else => return msgvec[index].hdr.iov[0].base[0..msgvec[index].len],
    }
}

pub fn udpPacketBufferSetPayload(
    send_buf: switch (builtin.os.tag) {
        .windows => *PacketBuffer,
        else => [*]std.c.mmsghdr,
    },
    index: usize,
    offset: usize,
    payload: []u8,
    // TODO: should be able to specify type here depending on OS
    peer_addr: ?*anyopaque,
) void {
    switch (builtin.os.tag) {
        .windows => {
            @memcpy(send_buf.buf[index], payload);
            @memcpy(std.mem.asBytes(&send_buf.addr[index]), @as([*]u8, @ptrCast(@alignCast(peer_addr)))[0..@sizeOf(std.posix.sockaddr.storage)]);
            send_buf.len[index] = payload.len;
        },
        else => {
            if (peer_addr) |addr| {
                @memcpy(std.mem.asBytes(@as(*std.c.sockaddr.storage, @ptrCast(@alignCast(send_buf[index].hdr.name.?)))), @as([*]u8, @ptrCast(@alignCast(addr)))[0..@sizeOf(std.c.sockaddr.storage)]);
                send_buf[index].hdr.namelen = switch (@as(*std.c.sockaddr, @ptrCast(@alignCast(addr))).family) {
                    std.c.AF.INET6 => @sizeOf(std.c.sockaddr.in6),
                    std.c.AF.INET => @sizeOf(std.c.sockaddr.in),
                    else => 0,
                };
            } else send_buf[index].hdr.namelen = 0;
            // might need to be set `null` on other platforms
            if (builtin.os.tag.isDarwin()) {
                send_buf[index].hdr.control = null;
            }
            send_buf[index].hdr.controllen = 0;
            send_buf[index].hdr.iov[0].len = payload.len + offset;
            @memcpy((send_buf[index].hdr.iov[0].base + offset)[0..payload.len], payload);
        },
    }
}

pub fn appleNoSigpipe(fd: std.posix.socket_t) std.posix.socket_t {
    if (builtin.os.tag.isDarwin()) {
        const val: c_int = 1;
        _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, &val, @sizeOf(c_int));
    }
    return fd;
}

pub fn setNonBlocking(fd: std.posix.socket_t) std.posix.socket_t {
    _ = switch (builtin.os.tag) {
        .windows => {},
        else => std.c.fcntl(fd, std.c.F.SETFL, std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0)) | @as(c_int, @bitCast(std.posix.O{ .NONBLOCK = true }))),
    };
    return fd;
}

pub fn socketNoDelay(fd: std.posix.socket_t, enabled: bool) void {
    const enabled_int: c_int = @intCast(@intFromBool(enabled));
    _ = std.c.setsockopt(fd, std.c.IPPROTO.TCP, std.c.TCP.NODELAY, &enabled_int, @sizeOf(c_int));
}

pub fn socketFlush(fd: std.posix.socket_t) void {
    // TODO: should only handle if TCP_CORK is defined/supported (might be able to simply catch error)
    if (@hasDecl(std.c.TCP, "CORK")) {
        const enabled: c_int = 0;
        _ = std.c.setsockopt(fd, std.c.IPPROTO.TCP, std.c.TCP.CORK, &enabled, @sizeOf(c_int));
    }
}

pub const SocketError = error{
    AddressFamilyNotSupported,
    ProtocolFamilyNotSupported,
    ProtocolNotSupported,
    SystemFdQuotaExceeded,
    ProcessFdQuotaExceeded,
    SystemResources,
    PermissionDenied,
    Unexpected,
};

pub fn createSocket(domain: u32, socktype: u32, protocol: u32) !std.posix.socket_t {
    var flags: u32 = 0;
    if (!builtin.os.tag.isDarwin() and @hasDecl(std.c.SOCK, "CLOEXEC") and @hasDecl(std.c.SOCK, "NONBLOCK")) {
        flags = std.c.SOCK.CLOEXEC | std.c.SOCK.NONBLOCK;
    }
    const raw_fd = std.c.socket(@intCast(domain), @intCast(socktype | flags), @intCast(protocol));
    switch (std.posix.errno(raw_fd)) {
        .SUCCESS => {},
        .ACCES => return error.PermissionDenied,
        .AFNOSUPPORT => return error.AddressFamilyNotSupported,
        .INVAL => return error.ProtocolFamilyNotSupported,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOBUFS => return error.SystemResources,
        .NOMEM => return error.SystemResources,
        .PROTONOSUPPORT => return error.ProtocolNotSupported,
        else => |err| return std.posix.unexpectedErrno(err),
    }
    const created_fd: std.posix.socket_t = switch (builtin.os.tag) {
        .windows => @ptrFromInt(@as(usize, @intCast(raw_fd))),
        else => @intCast(raw_fd),
    };
    return setNonBlocking(appleNoSigpipe(created_fd));
}

pub fn closeSocket(fd: std.posix.socket_t) void {
    _ = switch (builtin.os.tag) {
        .linux => std.os.linux.close(fd),
        else => std.c.close(fd),
    };
}

pub fn shutdownSocket(fd: std.posix.socket_t) void {
    _ = switch (builtin.os.tag) {
        .linux => std.os.linux.shutdown(fd, std.os.linux.SHUT.WR),
        else => std.c.shutdown(fd, std.c.SHUT.WR),
    };
}

pub fn shutdownSocketRead(fd: std.posix.socket_t) void {
    _ = switch (builtin.os.tag) {
        .linux => std.os.linux.shutdown(fd, std.os.linux.SHUT.RD),
        // Windows uses SD_RECEIVE, which has the same value as `std.c.SHUT.RD` (0)
        else => std.c.shutdown(fd, std.c.SHUT.RD),
    };
}

fn internalFinalizeBsdAddr(addr: *Addr) void {
    // TODO: verify that casting `&addr.mem` works as it does in the uSockets impl
    if (addr.mem.family == std.posix.AF.INET6) {
        addr.ip = &@as(*std.posix.sockaddr.in6, @ptrCast(@alignCast(addr))).addr;
        addr.ip_length = @intCast(@sizeOf(@FieldType(std.posix.sockaddr.in6, "addr")));
        addr.port = std.mem.bigToNative(u16, @as(*std.posix.sockaddr.in6, @ptrCast(@alignCast(addr))).port);
    } else if (addr.mem.family == std.posix.AF.INET) {
        addr.ip = std.mem.asBytes(&@as(*std.posix.sockaddr.in, @ptrCast(@alignCast(addr))).addr);
        addr.ip_length = @intCast(@sizeOf(@FieldType(std.posix.sockaddr.in, "addr")));
        addr.port = std.mem.bigToNative(u16, @as(*std.posix.sockaddr.in, @ptrCast(@alignCast(addr))).port);
    } else {
        addr.ip_length = 0;
        addr.port = -1;
    }
}

pub fn localAddr(fd: std.posix.socket_t, addr: *Addr) !void {
    addr.len = @sizeOf(std.posix.sockaddr.storage);
    if (std.c.getsockname(fd, @ptrCast(@alignCast(&addr.mem)), &addr.len) != 0) return error.LocalAddr;
    internalFinalizeBsdAddr(addr);
}

pub fn remoteAddr(fd: std.posix.socket_t, addr: *Addr) !void {
    addr.len = @sizeOf(std.posix.sockaddr.storage);
    switch (builtin.os.tag) {
        .linux => if (std.os.linux.getpeername(fd, @ptrCast(@alignCast(&addr.mem)), addr.len) != 0) return error.LinuxRemoteAddr,
        else => if (std.c.getpeername(fd, @ptrCast(@alignCast(&addr.mem)), addr.len) != 0) return error.RemoteAddr,
    }
    internalFinalizeBsdAddr(addr);
}

pub fn acceptSocket(fd: std.posix.socket_t, addr: *Addr) !std.posix.socket_t {
    addr.len = @sizeOf(std.posix.sockaddr.storage);
    const accepted_fd: std.posix.socket_t = switch (builtin.os.tag) {
        .linux => blk: {
            const ret = std.c.accept4(fd, @ptrCast(@alignCast(addr)), &addr.len, std.os.linux.SOCK.CLOEXEC | std.os.linux.SOCK.NONBLOCK);
            if (ret == -1) return error.AcceptSocket;
            break :blk @intCast(ret);
        },
        else => |tag| blk: {
            const ret = std.c.accept(fd, @ptrCast(@alignCast(addr)), &addr.len);
            if (ret == -1) return error.AcceptSocket;
            if (tag == .windows) break :blk @ptrFromInt(ret) else break :blk @intCast(ret);
        },
    };
    internalFinalizeBsdAddr(addr);
    return setNonBlocking(appleNoSigpipe(accepted_fd));
}

pub fn recv(fd: std.posix.socket_t, buf: []u8, flags: i32) isize {
    return @intCast(std.c.recv(fd, buf.ptr, buf.len, @intCast(flags)));
}

pub fn write2(fd: std.posix.socket_t, header: []const u8, payload: []const u8) isize {
    switch (builtin.os.tag) {
        .windows => {
            var chunks: [2]std.c.iovec = undefined;
            chunks[0].base = @constCast(header.ptr);
            chunks[0].len = header.len;
            chunks[1].base = @constCast(payload.ptr);
            chunks[1].len = payload.len;
            return std.c.writev(fd, (&chunks).ptr, 2);
        },
        else => {
            var written = send(fd, header, false);
            if (written == @as(isize, @intCast(header.len))) {
                const second_write = send(fd, payload, false);
                if (second_write > 0) {
                    written += second_write;
                }
            }
            return written;
        },
    }
}

pub fn send(fd: std.posix.socket_t, buf: []const u8, msg_more: bool) isize {
    const msg_nosignal = if (@hasDecl(std.posix.MSG, "NOSIGNAL")) std.c.MSG.NOSIGNAL else 0;
    if (@hasDecl(std.posix.MSG, "MORE"))
        return std.c.send(fd, @ptrCast(@alignCast(buf.ptr)), buf.len, @as(u32, @intCast(@intFromBool(msg_more))) * std.c.MSG.MORE | msg_nosignal)
    else
        return std.c.send(fd, @ptrCast(@alignCast(buf.ptr)), buf.len, msg_nosignal);
}

pub fn wouldBlock() bool {
    const errno: std.posix.E = @enumFromInt(std.c._errno().*);
    return switch (builtin.os.tag) {
        .windows => errno == .WOULDBLOCK,
        // AGAIN has the same value as WOULDBLOCK
        else => errno == .AGAIN,
    };
}

pub fn createListenSocket(host: ?[:0]const u8, port: u32, options: u32) !std.posix.socket_t {
    var hints = std.mem.zeroInit(std.posix.addrinfo, .{
        .flags = .{ .PASSIVE = true },
        .family = std.posix.AF.UNSPEC,
        .socktype = std.posix.SOCK.STREAM,
    });
    var result: ?*std.posix.addrinfo = undefined;

    var port_string_buf: [16]u8 = undefined;
    const port_string: [:0]u8 = try std.fmt.bufPrintSentinel(&port_string_buf, "{d}", .{port}, 0);
    if (@intFromEnum(std.c.getaddrinfo(if (host) |h| h.ptr else null, port_string.ptr, &hints, &result)) != 0) {
        return error.GetAddrInfo;
    }

    var listen_fd: ?std.posix.socket_t = null;
    var listen_addr: *std.posix.addrinfo = undefined;
    var maybe_a: ?*std.posix.addrinfo = result;
    while (maybe_a) |a| : (maybe_a = a.next) {
        if (a.family == std.posix.AF.INET6) {
            if (createSocket(@intCast(a.family), @intCast(a.socktype), @intCast(a.protocol))) |created_fd| {
                listen_fd = created_fd;
            } else |_| {}
            listen_addr = a;
        }
        if (listen_fd != null) break;
    }

    maybe_a = result;
    while (maybe_a) |a| : (maybe_a = a.next) {
        if (a.family == std.posix.AF.INET) {
            if (createSocket(@intCast(a.family), @intCast(a.socktype), @intCast(a.protocol))) |created_fd| {
                listen_fd = created_fd;
            } else |_| {}
            listen_addr = a;
        }
        if (listen_fd != null) break;
    }

    if (listen_fd == null) {
        std.c.freeaddrinfo(result.?);
        return error.CreateListenSocket;
    }
    const enabled: c_int = 1;
    const disabled: c_int = 0;

    if (port != 0) {
        if (builtin.os.tag == .windows) {
            if ((options & 1) != 0) {
                // hacky workaround for missing `std.c.SO.EXCLUSIVEADDRUSE`
                _ = std.c.setsockopt(listen_fd.?, std.c.SOL.SOCKET, ~std.c.SO.REUSEADDR, &enabled, @sizeOf(c_int));
            } else {
                _ = std.c.setsockopt(listen_fd.?, std.c.SOL.SOCKET, ~std.c.SO.REUSEADDR, &enabled, @sizeOf(c_int));
            }
        } else {
            if (@hasDecl(std.c.SO, "REUSEPORT")) {
                if ((options & 1) == 0) {
                    _ = std.c.setsockopt(listen_fd.?, std.c.SOL.SOCKET, std.c.SO.REUSEPORT, &enabled, @sizeOf(c_int));
                }
            }
            _ = std.c.setsockopt(listen_fd.?, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &enabled, @sizeOf(c_int));
        }
    }

    if (!(@typeInfo(c.IPV6) == .void) and @hasDecl(c.IPV6, "V6ONLY")) {
        _ = std.c.setsockopt(listen_fd.?, std.c.IPPROTO.IPV6, c.IPV6.V6ONLY, &disabled, @sizeOf(c_int));
    }
    if (std.c.bind(listen_fd.?, listen_addr.addr, listen_addr.addrlen) != 0 or std.c.listen(listen_fd.?, 512) != 0) {
        closeSocket(listen_fd.?);
        std.c.freeaddrinfo(result.?);
        return error.CreateListenSocket;
    }

    std.c.freeaddrinfo(result.?);
    return listen_fd.?;
}

pub fn createListenSocketUnix(path: [:0]const u8, _: u32) !std.posix.socket_t {
    const listen_fd = try createSocket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    if (builtin.os.tag != .windows) {
        _ = std.c.fchmod(listen_fd, std.posix.S.IRWXU);
    } else {
        _ = std.c.chmod(path.ptr, std.posix.S.IREAD | std.posix.S.IWRITE | std.posix.S.IEXEC);
    }

    var server_address: std.posix.sockaddr.un = std.mem.zeroInit(std.posix.sockaddr.un, .{
        .family = std.posix.AF.UNIX,
    });
    @memcpy(server_address.path[0..path.len], path);
    const size = @offsetOf(std.posix.sockaddr.un, "path") + path.len;
    _ = std.c.unlink(path.ptr);

    if (std.c.bind(listen_fd, @ptrCast(@alignCast(&server_address)), @intCast(size)) != 0 or std.c.listen(listen_fd, 512) != 0) {
        closeSocket(listen_fd);
        return error.CreateListenSocketUnix;
    }
    return listen_fd;
}

pub fn createUdpSocket(host: [:0]const u8, port: u32) !std.posix.socket_t {
    var hints = std.mem.zeroInit(std.posix.addrinfo, .{
        .flags = .{ .PASSIVE = true },
        .family = std.posix.AF.UNSPEC,
        .socktype = std.posix.SOCK.DGRAM,
    });
    var result: ?*std.posix.addrinfo = null;

    var port_str_buf: [16]u8 = undefined;
    const port_str: [:0]u8 = try std.fmt.bufPrintSentinel(&port_str_buf, "{d}", .{port}, 0);
    if (@intFromEnum(std.c.getaddrinfo(host.ptr, port_str.ptr, &hints, &result)) != 0) {
        return error.CreateUdpSocket;
    }

    var listen_fd: ?std.posix.socket_t = null;
    var listen_addr: *std.posix.addrinfo = undefined;
    var maybe_a: ?*std.posix.addrinfo = result;
    while (maybe_a) |a| : (maybe_a = a.next) {
        if (listen_fd != null) break;
        if (a.family == std.posix.AF.INET6) {
            if (createSocket(@intCast(a.family), @intCast(a.socktype), @intCast(a.protocol))) |created_fd| {
                listen_fd = created_fd;
            } else |_| {}
            listen_addr = a;
        }
    }

    maybe_a = result;
    while (maybe_a) |a| : (maybe_a = a.next) {
        if (listen_fd != null) break;
        if (a.family == std.posix.AF.INET) {
            if (createSocket(@intCast(a.family), @intCast(a.socktype), @intCast(a.protocol))) |created_fd| {
                listen_fd = created_fd;
            } else |_| {}
            listen_addr = a;
        }
    }

    if (listen_fd == null) {
        std.c.freeaddrinfo(result.?);
        return error.CreateUdpSocket;
    }

    const enabled: c_int = 1;
    const disabled: c_int = 0;

    if (port != 0) {
        _ = std.c.setsockopt(listen_fd.?, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &enabled, @sizeOf(c_int));
    }

    if (!(@typeInfo(c.IPV6) == .void) and @hasDecl(c.IPV6, "V6ONLY")) {
        _ = std.c.setsockopt(listen_fd.?, std.c.IPPROTO.IPV6, c.IPV6.V6ONLY, &disabled, @sizeOf(c_int));
    }

    if (!(@typeInfo(c.IPV6) == .void)) {
        const ipv6_recvpktinfo = if (!@hasDecl(c.IPV6, "RECVPKTINFO")) c.IPV6.PKTINFO else c.IPV6.RECVPKTINFO;
        if (std.c.setsockopt(listen_fd.?, std.posix.IPPROTO.IPV6, ipv6_recvpktinfo, &enabled, @sizeOf(c_int)) == -1) {
            if (std.c._errno().* == 92) {
                if (@hasDecl(c.IP, "PKTINFO")) {
                    if (std.c.setsockopt(listen_fd.?, std.posix.IPPROTO.IP, c.IP.PKTINFO, &enabled, @sizeOf(c_int)) != 0) {
                        std.debug.print("Error setting IPv4 pktinfo!\n", .{});
                    }
                } else if (@hasDecl(c.IP, "RECVDSTADDR")) {
                    if (std.c.setsockopt(listen_fd.?, std.posix.IPPROTO.IP, c.IP.RECVDSTADDR, &enabled, @sizeOf(c_int)) != 0) {
                        std.debug.print("Error setting IPv4 pktinfo!\n", .{});
                    }
                }
            } else {
                std.debug.print("Error setting IPv6 pktinfo!\n", .{});
            }
        }
    }

    if (std.c.setsockopt(listen_fd.?, std.posix.IPPROTO.IPV6, c.IPV6.RECVTCLASS, &enabled, @sizeOf(c_int)) == -1) {
        if (std.c._errno().* == 92) {
            if (std.c.setsockopt(listen_fd.?, std.posix.IPPROTO.IP, c.IP.RECVTOS, &enabled, @sizeOf(c_int)) != 0) {
                std.debug.print("Error setting IPv4 ECN!\n", .{});
            }
        } else {
            std.debug.print("Error setting IPv6 ECN!\n", .{});
        }
    }

    if (std.c.bind(listen_fd.?, listen_addr.addr, listen_addr.addrlen) != 0) {
        closeSocket(listen_fd.?);
        std.c.freeaddrinfo(result.?);
        return error.CreateUdpSocket;
    }
    std.c.freeaddrinfo(result.?);
    return listen_fd.?;
}

pub fn udpPacketBufferEcn(
    msgvec: switch (builtin.os.tag) {
        .windows => *PacketBuffer,
        else => [*]std.c.mmsghdr,
    },
    index: usize,
) u8 {
    if (builtin.os.tag.isDarwin() or builtin.os.tag == .windows) {
        std.debug.print("ECN not supported!\n", .{});
    } else {
        // TODO: implement for darwin
        const mh = msgvec[index].hdr;
        var maybe_cmsg = cmsg.firsthdr(mh);
        while (maybe_cmsg) |c_| : (maybe_cmsg = cmsg.nexthdr(mh, c_)) {
            if (c_.level == std.posix.IPPROTO.IP and c_.type == c.IP.TOS) {
                const tos: u8 = cmsg.data(c_).*;
                return tos & 3;
            }
            if (c_.level == std.posix.IPPROTO.IPV6 and c_.type == c.IPV6.TCLASS) {
                const tos: u8 = cmsg.data(c_).*;
                return tos & 3;
            }
        }
    }
    std.debug.print("We got no ECN!\n", .{});
    return 0;
}

pub fn createConnectSocket(host: [:0]const u8, port: u32, source_host: ?[:0]const u8, _: u32) !std.posix.socket_t {
    var hints: std.posix.addrinfo = std.mem.zeroInit(std.posix.addrinfo, .{
        .family = std.posix.AF.UNSPEC,
        .socktype = std.posix.SOCK.STREAM,
        .flags = .{
            .ADDRCONFIG = true,
        },
    });
    var result: ?*std.posix.addrinfo = null;

    var port_string_buf: [16]u8 = undefined;
    const port_str: [:0]u8 = try std.fmt.bufPrintSentinel(&port_string_buf, "{d}", .{port}, 0);

    if (@intFromEnum(std.c.getaddrinfo(host.ptr, port_str.ptr, &hints, &result)) != 0) {
        return error.CreateConnectSocket;
    }

    const fd = createSocket(@intCast(result.?.family), @intCast(result.?.socktype), @intCast(result.?.protocol)) catch |err| {
        std.c.freeaddrinfo(result.?);
        return err;
    };

    if (source_host) |sh| {
        var interface_result: ?*std.posix.addrinfo = null;
        if (@intFromEnum(std.c.getaddrinfo(sh, null, null, &interface_result)) == 0) {
            const ret = std.c.bind(fd, interface_result.?.addr, interface_result.?.addrlen);
            std.c.freeaddrinfo(interface_result.?);
            if (ret == -1) {
                closeSocket(fd);
                std.c.freeaddrinfo(result.?);
                return error.FailedCreateConnectSocket;
            }
        }
    }

    _ = std.c.connect(fd, result.?.addr.?, result.?.addrlen);
    std.c.freeaddrinfo(result.?);
    return fd;
}

pub fn createConnectSocketUnix(server_path: [:0]const u8, _: u32) !std.posix.socket_t {
    var server_address = std.mem.zeroInit(std.posix.sockaddr.un, .{
        .family = std.posix.AF.UNIX,
    });
    @memcpy(server_address.path[0..server_path.len], server_path);
    const size = @offsetOf(std.posix.sockaddr.un, "path") + server_path.len;
    const fd = try createSocket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    _ = std.c.connect(fd, @ptrCast(@alignCast(&server_address)), @intCast(size));
    return fd;
}
