const builtin = @import("builtin");
const epoll = @import("fuzzing/epoll.zig");
const std = @import("std");

const native_os = builtin.os.tag;

// hacky workaround for zig having `std.c.darwin.IP`/`std.c.darwin.IPV6`
// set to `void` even though the definitions exist in `c/darwin.zig`

pub const IP = switch (native_os) {
    .linux, .freebsd, .dragonfly, .netbsd, .openbsd, .illumos, .haiku, .serenity => std.c.IP,
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => struct {
        pub const OPTIONS = 1;
        pub const HDRINCL = 2;
        pub const TOS = 3;
        pub const TTL = 4;
        pub const RECVOPTS = 5;
        pub const RECVRETOPTS = 6;
        pub const RECVDSTADDR = 7;
        pub const RETOPTS = 8;
        pub const MULTICAST_IF = 9;
        pub const MULTICAST_TTL = 10;
        pub const MULTICAST_LOOP = 11;
        pub const ADD_MEMBERSHIP = 12;
        pub const DROP_MEMBERSHIP = 13;
        pub const MULTICAST_VIF = 14;
        pub const RSVP_ON = 15;
        pub const RSVP_OFF = 16;
        pub const RSVP_VIF_ON = 17;
        pub const RSVP_VIF_OFF = 18;
        pub const PORTRANGE = 19;
        pub const RECVIF = 20;
        pub const IPSEC_POLICY = 21;
        pub const FAITH = 22;
        pub const STRIPHDR = 23;
        pub const RECVTTL = 24;
        pub const BOUND_IF = 25;
        pub const PKTINFO = 26;
        pub const RECVPKTINFO = PKTINFO;
        pub const RECVTOS = 27;
        pub const DONTFRAG = 28;
        pub const FW_ADD = 40;
        pub const FW_DEL = 41;
        pub const FW_FLUSH = 42;
        pub const FW_ZERO = 43;
        pub const FW_GET = 44;
        pub const FW_RESETLOG = 45;
        pub const OLD_FW_ADD = 50;
        pub const OLD_FW_DEL = 51;
        pub const OLD_FW_FLUSH = 52;
        pub const OLD_FW_ZERO = 53;
        pub const OLD_FW_GET = 54;
        pub const OLD_FW_RESETLOG = 56;
        pub const DUMMYNET_CONFIGURE = 60;
        pub const DUMMYNET_DEL = 61;
        pub const DUMMYNET_FLUSH = 62;
        pub const DUMMYNET_GET = 64;
        pub const TRAFFIC_MGT_BACKGROUND = 65;
        pub const MULTICAST_IFINDEX = 66;
        pub const ADD_SOURCE_MEMBERSHIP = 70;
        pub const DROP_SOURCE_MEMBERSHIP = 71;
        pub const BLOCK_SOURCE = 72;
        pub const UNBLOCK_SOURCE = 73;
        pub const MSFILTER = 74;
        // Same namespace, but these are arguments rather than option names
        pub const DEFAULT_MULTICAST_TTL = 1;
        pub const DEFAULT_MULTICAST_LOOP = 1;
        pub const MIN_MEMBERSHIPS = 31;
        pub const MAX_MEMBERSHIPS = 4095;
        pub const MAX_GROUP_SRC_FILTER = 512;
        pub const MAX_SOCK_SRC_FILTER = 128;
        pub const MAX_SOCK_MUTE_FILTER = 128;
        pub const PORTRANGE_DEFAULT = 0;
        pub const PORTRANGE_HIGH = 1;
        pub const PORTRANGE_LOW = 2;
    },
    else => void,
};

pub const IPV6 = switch (native_os) {
    .linux, .freebsd, .dragonfly, .netbsd, .openbsd, .illumos, .haiku, .serenity => std.c.IPV6,
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => struct {
        pub const UNICAST_HOPS = 4;
        pub const MULTICAST_IF = 9;
        pub const MULTICAST_HOPS = 10;
        pub const MULTICAST_LOOP = 11;
        pub const JOIN_GROUP = 12;
        pub const LEAVE_GROUP = 13;
        pub const PORTRANGE = 14;
        pub const @"2292PKTINFO" = 19;
        pub const @"2292HOPLIMIT" = 20;
        pub const @"2292NEXTHOP" = 21;
        pub const @"2292HOPOPTS" = 22;
        pub const @"2292DSTOPTS" = 23;
        pub const @"2292RTHDR" = 24;
        pub const @"2292PKTOPTIONS" = 25;
        pub const CHECKSUM = 26;
        pub const V6ONLY = 27;
        pub const BINDV6ONLY = V6ONLY;
        pub const IPSEC_POLICY = 28;
        pub const FAITH = 29;
        pub const FW_ADD = 30;
        pub const FW_DEL = 31;
        pub const FW_FLUSH = 32;
        pub const FW_ZERO = 33;
        pub const FW_GET = 34;
        pub const RECVTCLASS = 35;
        pub const TCLASS = 36;
        pub const RTHDRDSTOPTS = 57;
        pub const RECVPKTINFO = 61;
        pub const RECVHOPLIMIT = 37;
        pub const RECVRTHDR = 38;
        pub const RECVHOPOPTS = 39;
        pub const RECVDSTOPTS = 40;
        pub const RECVRTHDRDSTOPTS = 41;
        pub const USE_MIN_MTU = 42;
        pub const RECVPATHMTU = 43;
        pub const PATHMTU = 44;
        pub const REACHCONF = 45;
        pub const @"3542PKTINFO" = 46;
        pub const @"3542HOPLIMIT" = 47;
        pub const @"3542NEXTHOP" = 48;
        pub const @"3542HOPOPTS" = 49;
        pub const @"3542DSTOPTS" = 50;
        pub const @"3542RTHDR" = 51;
        pub const PKTINFO = @"3542PKTINFO";
        pub const HOPLIMIT = @"3542HOPLIMIT";
        pub const NEXTHOP = @"3542NEXTHOP";
        pub const HOPOPTS = @"3542HOPOPTS";
        pub const DSTOPTS = @"3542DSTOPTS";
        pub const RTHDR = @"3542RTHDR";
        pub const AUTOFLOWLABEL = 59;
        pub const DONTFRAG = 62;
        pub const PREFER_TEMPADDR = 63;
        pub const MSFILTER = 74;
        pub const BOUND_IF = 125;
        // Same namespace, but these are arguments rather than option names
        pub const RTHDR_LOOSE = 0;
        pub const RTHDR_STRICT = 1;
        pub const RTHDR_TYPE_0 = 0;
        pub const DEFAULT_MULTICAST_HOPS = 1;
        pub const DEFAULT_MULTICAST_LOOP = 1;
        pub const MIN_MEMBERSHIPS = 31;
        pub const MAX_MEMBERSHIPS = 4095;
        pub const MAX_GROUP_SRC_FILTER = 512;
        pub const MAX_SOCK_SRC_FILTER = 128;
        pub const PORTRANGE_DEFAULT = 0;
        pub const PORTRANGE_HIGH = 1;
        pub const PORTRANGE_LOW = 2;
    },
    else => void,
};

// TODO: check whether OS supports `sendmsg_x`/`recvmsg_x`
pub fn supportSendRecvMsgX() bool {
    if (builtin.target.os.tag == .macos and builtin.target.os.versionRange().semver.isAtLeast(.{ .major = 15, .minor = 6, .patch = 0 }).?) {
        // std.debug.print("supports `sendmsg_x`/`recvmsg_x`\n", .{});
        return true;
    }
    return false;
}

pub extern "c" fn sendmsg_x(s: std.c.fd_t, msgp: [*]const std.c.mmsghdr, cnt: c_uint, flags: c_int) isize;
pub extern "c" fn recvmsg_x(s: std.c.fd_t, msgp: [*]const std.c.mmsghdr, cnt: c_uint, flags: c_int) isize;

// wrap `std.c` functions, calling epoll fuzzer shim if we're fuzzing
pub fn send(sockfd: std.c.fd_t, buf: *const anyopaque, len: usize, flags: u32) isize {
    if (comptime epoll.isEpollFuzzing()) {
        return epoll.send(sockfd, buf, len, flags);
    } else {
        return std.c.send(sockfd, buf, len, flags);
    }
}

pub fn recv(
    sockfd: std.c.fd_t,
    arg1: ?*anyopaque,
    arg2: usize,
    arg3: c_int,
) if (builtin.os.tag == .windows) c_int else isize {
    if (comptime epoll.isEpollFuzzing()) {
        return epoll.recv(sockfd, arg1, arg2, arg3);
    } else {
        return std.c.recv(sockfd, arg1, arg2, arg3);
    }
}

pub fn listen(sockfd: std.c.fd_t, backlog: c_uint) c_int {
    if (comptime epoll.isEpollFuzzing()) {
        return epoll.listen(sockfd, backlog);
    } else {
        return std.c.listen(sockfd, backlog);
    }
}

pub fn getaddrinfo(
    noalias node: ?[*:0]const u8,
    noalias service: ?[*:0]const u8,
    noalias hints: ?*const std.c.addrinfo,
    /// On Linux, `res` will not be modified on error and `freeaddrinfo` will
    /// potentially crash if you pass it an undefined pointer
    noalias res: *?*std.c.addrinfo,
) std.c.EAI {
    if (comptime epoll.isEpollFuzzing()) {
        return epoll.getaddrinfo(node, service, hints, res);
    } else {
        return std.c.getaddrinfo(node, service, hints, res);
    }
}

pub fn freeaddrinfo(res: *std.c.addrinfo) void {
    if (comptime epoll.isEpollFuzzing()) {
        return epoll.freeaddrinfo(res);
    } else {
        return std.c.freeaddrinfo(res);
    }
}

pub fn setsockopt(sockfd: std.c.fd_t, level: i32, optname: u32, optval: ?*const anyopaque, optlen: std.c.socklen_t) c_int {
    if (comptime epoll.isEpollFuzzing()) {
        return epoll.setsockopt(sockfd, level, optname, optval, optlen);
    } else {
        return std.c.setsockopt(sockfd, level, optname, optval, optlen);
    }
}

pub fn fcntl(fd: std.c.fd_t, cmd: c_int, arg: c_int) c_int {
    if (comptime epoll.isEpollFuzzing()) {
        return epoll.fcntl(fd, cmd, arg);
    } else {
        return std.c.fcntl(fd, cmd, arg);
    }
}

pub fn bind(sock: std.c.fd_t, address: ?*const std.c.sockaddr, address_len: std.c.socklen_t) c_int {
    if (comptime epoll.isEpollFuzzing()) {
        return epoll.bind(sock, address, address_len);
    } else {
        return std.c.bind(sock, address, address_len);
    }
}

pub fn socket(domain: c_uint, sock_type: c_uint, protocol: c_uint) c_int {
    if (comptime epoll.isEpollFuzzing()) {
        return epoll.socket(domain, sock_type, protocol);
    } else {
        return std.c.socket(domain, sock_type, protocol);
    }
}

pub fn close(fd: std.c.fd_t) c_int {
    if (comptime epoll.isEpollFuzzing()) {
        return epoll.c_close(fd);
    } else {
        return std.c.close(fd);
    }
}

pub fn accept4(sockfd: std.c.fd_t, noalias addr: ?*std.c.sockaddr, noalias addrlen: ?*std.c.socklen_t, flags: c_uint) c_int {
    if (comptime epoll.isEpollFuzzing()) {
        return epoll.accept4(sockfd, addr, addrlen, flags);
    } else {
        return std.c.accept4(sockfd, addr, addrlen, flags);
    }
}
