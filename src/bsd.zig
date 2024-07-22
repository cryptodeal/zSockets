const builtin = @import("builtin");
const internal = @import("internal.zig");
const std = @import("std");

const PortOptions = internal.PortOptions;
const SocketDescriptor = internal.SocketDescriptor;
const SOCKET_ERROR = internal.SOCKET_ERROR;

pub const BsdAddr = struct {
    mem: std.posix.sockaddr.storage,
    len: std.posix.socklen_t,
    ip: []u8,
    port: ?std.c.in_port_t,

    pub fn getIp(self: *const BsdAddr) []u8 {
        return self.ip;
    }
};

fn internalFinalizeBsdAddr(addr: *BsdAddr) void {
    // essentially parse the address
    switch (addr.mem.family) {
        std.posix.AF.INET6 => {
            addr.ip = &@as(*std.c.sockaddr.in6, @ptrCast(@alignCast(&addr.mem))).addr;
            addr.port = @as(*std.c.sockaddr.in6, @ptrCast(@alignCast(&addr.mem))).port;
        },
        std.posix.AF.INET => {
            addr.ip = std.mem.asBytes(&@as(*std.c.sockaddr.in, @ptrCast(@alignCast(&addr.mem))).addr);
            addr.port = @as(*std.c.sockaddr.in, @ptrCast(@alignCast(&addr.mem))).port;
        },
        else => {
            addr.ip = &[_]u8{};
            addr.port = null;
        },
    }
}

pub fn acceptSocket(fd: SocketDescriptor, addr: *BsdAddr) !SocketDescriptor {
    var accepted_fd: SocketDescriptor = undefined;
    addr.len = @intCast(@sizeOf(std.posix.sockaddr.storage));
    if (@hasDecl(std.posix, "SOCK") and @hasDecl(std.posix.SOCK, "CLOEXEC") and @hasDecl(std.c.SOCK, "NONBLOCK")) {
        // Linux, FreeBSD
        accepted_fd = try std.posix.accept(fd, @ptrCast(@alignCast(&addr.mem)), &addr.len, std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK);
    } else {
        // Windows, OSx
        accepted_fd = try std.posix.accept(fd, @ptrCast(@alignCast(&addr.mem)), &addr.len, 0);
    }
    // We cannot rely on addr since it is not initialized if failed
    if (accepted_fd == SOCKET_ERROR) return error.SocketError;
    internalFinalizeBsdAddr(addr);
    return setNonblocking(try appleNoSigpipe(accepted_fd));
}

// Emulate `sendmmsg`/`recvmmsg` on platform that don't support it.
pub fn sendMmsg(fd: SocketDescriptor, msgvec: ?*anyopaque, vlen: usize, flags: u32) !void {
    _ = fd; // autofix
    _ = msgvec; // autofix
    _ = vlen; // autofix
    _ = flags; // autofix
}

pub fn send(fd: SocketDescriptor, buf: []const u8, msg_more: bool) !usize {
    return switch (builtin.os.tag) {
        .linux => std.posix.send(fd, buf, (@intFromBool(msg_more) * std.posix.MSG.MORE) | std.posix.MSG.NOSIGNAL),
        else => std.posix.send(fd, buf, 0),
    };
}

pub fn flushSocket(fd: SocketDescriptor) !void {
    try std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, std.os.linux.TCP.CORK, &.{0});
}

pub fn shutdownSocket(fd: SocketDescriptor) !void {
    return std.posix.shutdown(fd, .send);
}

pub fn setNodelay(fd: SocketDescriptor, enabled: bool) !void {
    const val: u8 = @intCast(@intFromBool(enabled));
    return std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, std.os.linux.TCP.NODELAY, &.{val});
}

pub fn appleNoSigpipe(fd: SocketDescriptor) !SocketDescriptor {
    if (builtin.os.tag.isDarwin() and fd != SOCKET_ERROR) {
        const val: i32 = 1;
        _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, &val, @sizeOf(i32));
    }
    return fd;
}

pub fn setNonblocking(fd: SocketDescriptor) !SocketDescriptor {
    switch (builtin.target.os.tag) {
        .windows => {}, // handled by libuv
        else => _ = try std.posix.fcntl(
            fd,
            std.posix.F.SETFL,
            (try std.posix.fcntl(fd, std.posix.F.GETFL, 0)) | std.posix.SOCK.NONBLOCK,
        ),
    }
    return fd;
}

pub fn createSocket(domain: u32, socket_type: u32, protocol: u32) !SocketDescriptor {
    var flags: u32 = 0;
    if (@hasDecl(std.posix, "SOCK") and @hasDecl(std.posix.SOCK, "CLOEXEC") and @hasDecl(std.c.SOCK, "NONBLOCK")) {
        flags = std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK;
    }
    const created_fd = try std.posix.socket(domain, socket_type | flags, protocol);
    return setNonblocking(try appleNoSigpipe(created_fd));
}

pub fn closeSocket(fd: SocketDescriptor) !void {
    return switch (builtin.target.os.tag) {
        .windows => std.os.closesocket(fd),
        else => std.posix.close(fd),
    };
}

pub fn createListenSocket(host: ?[:0]const u8, port: u64, options: u64) !SocketDescriptor {
    const hints: std.c.addrinfo = std.mem.zeroInit(std.c.addrinfo, .{
        .flags = std.c.AI.PASSIVE,
        .family = std.c.AF.UNSPEC,
        .socktype = std.c.SOCK.STREAM,
    });
    var result: ?*std.c.addrinfo = null;
    defer if (result) |r| std.c.freeaddrinfo(r);

    var buf: [16]u8 = [_]u8{'\x00'} ** 16;
    const port_string: [*:0]const u8 = @ptrCast(buf[0 .. std.fmt.formatIntBuf(buf[0..], port, 10, .lower, .{}) + 1].ptr);
    if (@intFromEnum(std.c.getaddrinfo(if (host) |h| h.ptr else null, port_string, &hints, &result)) != 0) {
        return error.SocketError;
    }
    var listen_fd: SocketDescriptor = SOCKET_ERROR;
    var listen_addr: ?*std.c.addrinfo = null;
    var a: ?*std.c.addrinfo = result;
    while (a != null and listen_fd == SOCKET_ERROR) : (a = a.?.next) {
        if (a.?.family == std.c.AF.INET6) {
            // TODO: finish implementing
            listen_fd = try createSocket(@intCast(a.?.family), @intCast(a.?.socktype), @intCast(a.?.protocol));
            listen_addr = a;
        }
    }

    a = result;
    while (a != null and listen_fd == SOCKET_ERROR) : (a = a.?.next) {
        if (a.?.family == std.c.AF.INET) {
            // TODO: finish implementing
            listen_fd = try createSocket(@intCast(a.?.family), @intCast(a.?.socktype), @intCast(a.?.protocol));
            listen_addr = a;
        }
    }

    if (listen_fd == SOCKET_ERROR) return error.SocketError;

    const enabled: i32 = 1;
    const disabled: i32 = 0;
    if (port != 0) {
        switch (builtin.target.os.tag) {
            .windows => {
                if ((options & @intFromEnum(PortOptions.exclusive)) != 0) {
                    const SO_EXCLUSIVEADDRUSE = ~@as(u32, std.c.SO.REUSEADDR); // hacky way to expose this option name
                    _ = std.c.setsockopt(listen_fd, std.c.SOL.SOCKET, SO_EXCLUSIVEADDRUSE, &enabled, @sizeOf(i32));
                } else {
                    _ = std.c.setsockopt(listen_fd, std.c.SOL.SOCKET, std.posix.SO.REUSEADDR, &enabled, @sizeOf(i32));
                }
            },
            else => {
                if (@hasDecl(std.posix.SO, "REUSEPORT")) {
                    _ = std.c.setsockopt(listen_fd, std.c.SOL.SOCKET, std.c.SO.REUSEPORT, &enabled, @sizeOf(i32));
                }
                _ = std.c.setsockopt(listen_fd, std.c.SOL.SOCKET, std.c.SO.REUSEPORT, &enabled, @sizeOf(i32));
            },
        }
    }

    switch (builtin.target.os.tag) {
        .linux => try std.c.setsockopt(listen_fd, std.c.IPPROTO.IPV6, std.c.linux.IPV6.V6ONLY, &disabled, @sizeOf(i32)),
        .windows => try std.c.setsockopt(listen_fd, std.c.IPPROTO.IPV6, std.os.windows.ws2_32.IPV6_V6ONLY, &disabled, @sizeOf(i32)),
        else => {},
    }

    std.posix.bind(listen_fd, listen_addr.?.addr.?, listen_addr.?.addrlen) catch |err| {
        try closeSocket(listen_fd);
        return err;
    };
    std.posix.listen(listen_fd, 512) catch |err| {
        try closeSocket(listen_fd);
        return err;
    };

    return listen_fd;
}

pub fn recv(fd: SocketDescriptor, buf: []u8, flags: u32) !usize {
    return std.posix.recv(fd, buf, flags);
}
