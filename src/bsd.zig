const builtin = @import("builtin");
const std = @import("std");
const zs = @import("zsockets.zig");

pub const c = @cImport({
    @cInclude("bsd.h");
});

pub fn setNoDelay(fd: zs.SocketDescriptor, enabled: bool) void {
    const enabled_int: u1 = @intFromBool(enabled);
    _ = std.c.setsockopt(fd, std.c.IPPROTO.TCP, 1, &enabled_int, @sizeOf(u1));
}

pub fn closeSocket(fd: zs.SocketDescriptor) !void {
    return switch (builtin.target.os.tag) {
        // TODO(cryptodeal): need to verify windows implementation works
        .windows => try std.os.closesocket(fd),
        else => _ = std.c.close(fd),
    };
}

pub fn acceptSocket(fd: zs.SocketDescriptor, addr: *c.bsd_addr_t) zs.SocketDescriptor {
    var accepted_fd: zs.SocketDescriptor = undefined;
    addr.len = @intCast(@sizeOf(@TypeOf(addr.mem)));
    if (@hasDecl(std.os, "SOCK") and @hasDecl(std.os.SOCK, "CLOEXEC") and @hasDecl(std.os.SOCK, "NONBLOCK")) {
        // Linux, FreeBSD
        accepted_fd = std.c.accept4(fd, @ptrCast(addr), &addr.len, std.c.SOCK.CLOEXEC | std.c.SOCK.NONBLOCK);
    } else {
        // Windows, OSx
        accepted_fd = std.c.accept(fd, @ptrCast(addr), &addr.len);
    }
    // We cannot rely on addr since it is not initialized if failed
    if (accepted_fd == zs.SOCKET_ERROR) return zs.SOCKET_ERROR;
    internalFinalizeBsdAddr(addr);
    return setNonblocking(appleNoSigpipe(accepted_fd));
}

pub fn appleNoSigpipe(fd: zs.SocketDescriptor) zs.SocketDescriptor {
    if (builtin.os.tag.isDarwin() and fd != zs.SOCKET_ERROR) {
        const enabled: c_int = 1;
        _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, &enabled, @sizeOf(c_int));
    }
    return fd;
}

pub fn setNonblocking(fd: zs.SocketDescriptor) zs.SocketDescriptor {
    switch (builtin.target.os.tag) {
        .windows => {}, // handled by libuv
        else => _ = std.c.fcntl(
            fd,
            std.c.F.SETFL,
            std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0)) | c.O_NONBLOCK,
        ),
    }
    return fd;
}

pub fn recv(fd: zs.SocketDescriptor, buf: []u8, flags: u32) if (builtin.os.tag == .windows) c_int else isize {
    return std.c.recv(fd, buf.ptr, buf.len, @intCast(flags));
}

pub fn send(fd: zs.SocketDescriptor, buf: []const u8, msg_more: bool) isize {
    if (@hasDecl(std.os, "MSG") and @hasDecl(std.os.MSG, "MORE")) {
        return std.c.send(fd, buf.ptr, buf.len, (@intFromBool(msg_more) * std.os.MSG.MORE) | std.os.MSG.NOSIGNAL);
    } else {
        return std.c.send(fd, buf.ptr, buf.len, 0);
    }
}

const WSAEWOULDBLOCK = 10035;
pub fn wouldBlock() bool {
    return switch (builtin.os.tag) {
        .windows => std.os.WSAGetLastError() == std.os.WinsockError.WSAEWOULDBLOCK,
        else => @as(std.c.E, @enumFromInt(std.c._errno().*)) == .AGAIN,
    };
}

pub fn createConnectSocket(host: ?[:0]const u8, port: u64, src_host: ?[:0]const u8, _: u64) !zs.SocketDescriptor {
    const hints: std.c.addrinfo = std.mem.zeroInit(std.c.addrinfo, .{
        .family = std.c.AF.UNSPEC,
        .socktype = std.c.SOCK.STREAM,
    });
    var result: ?*std.c.addrinfo = null;
    defer if (result) |r| std.c.freeaddrinfo(r);

    var buf: [16]u8 = undefined;
    const port_string: [:0]u8 = std.fmt.bufPrintZ(&buf, "{d}", .{port}) catch unreachable;
    if (@intFromEnum(std.c.getaddrinfo(if (host) |h| h.ptr else null, port_string.ptr, &hints, &result)) != 0) {
        return zs.SOCKET_ERROR;
    }
    const fd = createSocket(@intCast(result.?.family), @intCast(result.?.socktype), @intCast(result.?.protocol));
    if (fd == zs.SOCKET_ERROR) return zs.SOCKET_ERROR;

    if (src_host) |sh| {
        var interface_result: ?*std.c.addrinfo = null;
        defer if (interface_result) |ir| std.c.freeaddrinfo(ir);
        if (@intFromEnum(std.c.getaddrinfo(sh.ptr, null, null, &interface_result)) == 0) {
            const ret = std.c.bind(fd, interface_result.?.addr, @intCast(interface_result.?.addrlen));
            if (ret == zs.SOCKET_ERROR) {
                try closeSocket(fd);
                return zs.SOCKET_ERROR;
            }
        }
    }

    _ = std.c.connect(fd, result.?.addr.?, @intCast(result.?.addrlen));
    return fd;
}

pub fn createSocket(domain: u32, socket_type: u32, protocol: u32) zs.SocketDescriptor {
    var flags: u32 = 0;
    if (@hasDecl(std.os, "SOCK") and @hasDecl(std.os.SOCK, "CLOEXEC") and @hasDecl(std.os.SOCK, "NONBLOCK")) {
        flags = std.c.SOCK.CLOEXEC | std.c.SOCK.NONBLOCK;
    }
    // std.debug.print("domain: {d}, socket_t: {d}, protocol: {d}\n", .{ domain, socket_type | flags, protocol });
    const created_fd = std.c.socket(domain, socket_type | flags, protocol);
    // std.debug.print("created_fd: {d}\n", .{created_fd});
    return setNonblocking(appleNoSigpipe(created_fd));
}

pub fn createListenSocket(host: ?[:0]const u8, port: u64, options: u64) !zs.SocketDescriptor {
    const hints: std.c.addrinfo = std.mem.zeroInit(std.c.addrinfo, .{
        .flags = std.c.AI.PASSIVE,
        .family = std.c.AF.UNSPEC,
        .socktype = std.c.SOCK.STREAM,
    });
    var result: ?*std.c.addrinfo = null;
    defer if (result) |r| std.c.freeaddrinfo(r);

    var buf: [16]u8 = undefined;
    const port_string: [:0]u8 = std.fmt.bufPrintZ(&buf, "{d}", .{port}) catch unreachable;
    if (@intFromEnum(std.c.getaddrinfo(if (host) |h| h.ptr else null, port_string.ptr, &hints, &result)) != 0) {
        return zs.SOCKET_ERROR;
    }
    var listen_fd: zs.SocketDescriptor = zs.SOCKET_ERROR;
    var listen_addr: ?*std.c.addrinfo = null;
    var a: ?*std.c.addrinfo = result;
    while (a != null and listen_fd == zs.SOCKET_ERROR) : (a = a.?.next) {
        if (a.?.family == std.c.AF.INET6) {
            listen_fd = createSocket(@intCast(a.?.family), @intCast(a.?.socktype), @intCast(a.?.protocol));
            listen_addr = a;
        }
    }

    a = result;
    while (a != null and listen_fd == zs.SOCKET_ERROR) : (a = a.?.next) {
        if (a.?.family == std.c.AF.INET) {
            listen_fd = createSocket(@intCast(a.?.family), @intCast(a.?.socktype), @intCast(a.?.protocol));
            listen_addr = a;
        }
    }

    if (listen_fd == zs.SOCKET_ERROR) return zs.SOCKET_ERROR;

    const enabled: c_int = 1;
    const disabled: c_int = 0;
    // std.debug.print("listen_fd: {d}\n", .{listen_fd});
    if (port != 0) {
        switch (builtin.target.os.tag) {
            .windows => {
                if ((options & @intFromEnum(zs.PortOptions.exclusive)) != 0) {
                    const SO_EXCLUSIVEADDRUSE = ~@as(u32, std.c.SO.REUSEADDR); // hacky way to expose this option name
                    _ = std.c.setsockopt(listen_fd, std.c.SOL.SOCKET, SO_EXCLUSIVEADDRUSE, &enabled, @sizeOf(c_int));
                } else {
                    _ = std.c.setsockopt(listen_fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &enabled, @sizeOf(c_int));
                }
            },
            else => {
                if (@hasDecl(std.c, "SO") and @hasDecl(std.c.SO, "REUSEPORT") and (options & @intFromEnum(zs.PortOptions.exclusive)) == 0) {
                    _ = std.c.setsockopt(listen_fd, std.c.SOL.SOCKET, std.c.SO.REUSEPORT, &enabled, @sizeOf(c_int));
                }
                _ = std.c.setsockopt(listen_fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &enabled, @sizeOf(c_int));
            },
        }
    }

    if (@hasDecl(std.c, "IPV6_V6ONLY")) {
        _ = std.c.setsockopt(listen_fd, std.c.IPPROTO.IPV6, std.c.IPV6_V6ONLY, &disabled, @sizeOf(c_int));
    } else if (@hasDecl(std.c, "IPV6") and @hasDecl(std.c.IPV6, "V6ONLY")) {
        _ = std.c.setsockopt(listen_fd, std.c.IPPROTO.IPV6, std.c.IPV6.V6ONLY, &disabled, @sizeOf(c_int));
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

pub fn shutdownSocket(fd: zs.SocketDescriptor) void {
    _ = std.c.shutdown(fd, std.c.SHUT.WR);
}

// internal functions
fn internalFinalizeBsdAddr(addr: *c.bsd_addr_t) void {
    // essentially parse the address
    switch (addr.mem.ss_family) {
        std.c.AF.INET6 => {
            addr.ip = @ptrCast(@alignCast(&@as(*c.sockaddr_in6, @ptrCast(@alignCast(addr))).sin6_addr));
            addr.ip_length = @sizeOf(c.in6_addr);
            addr.port = @as(*c.sockaddr_in6, @ptrCast(@alignCast(addr))).sin6_port;
        },
        std.c.AF.INET => {
            addr.ip = @ptrCast(@alignCast(&@as(*c.sockaddr_in, @ptrCast(@alignCast(addr))).sin_addr));
            addr.ip_length = @sizeOf(c.in_addr);
            addr.port = @as(*c.sockaddr_in, @ptrCast(@alignCast(addr))).sin_port;
        },
        else => {
            addr.ip = 0;
            addr.port = -1;
        },
    }
}

pub fn internalGetIp(addr: *c.bsd_addr_t) []u8 {
    return @as([*]u8, @ptrCast(@alignCast(addr.ip)))[0..@intCast(addr.ip_length)];
}
