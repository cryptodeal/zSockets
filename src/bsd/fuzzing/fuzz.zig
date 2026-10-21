const builtin = @import("builtin");
const build_opts = @import("build_opts");
const std = @import("std");

pub fn isEpollFuzzing() bool {
    // TODO: `builtin.fuzz` should be checked, but its not being set to true currently
    return builtin.is_test and build_opts.epoll_fuzz and builtin.os.tag == .linux and @import("build_opts").event_backend == .epoll;
}

var teardown: *const fn () void = undefined;

pub fn setTeardown(func: *const fn () void) void {
    teardown = func;
}

const File = extern struct {
    type: i32,
    epev: std.c.epoll_event,
    prev: ?*File,
    next: ?*File,
};

const reserved_system_fds = 1024;
const max_fds = 1000;
var fd_to_file: [max_fds]?*File = @splat(null);

const FdType = enum(i32) {
    epoll,
    timer,
    event,
    socket,
};

var num_fds: u32 = 0;

pub fn numFds() u32 {
    return num_fds;
}

var consumable_data: []u8 = &.{};

pub fn setConsumableData(new_data: []const u8) void {
    consumable_data = @constCast(new_data);
}

fn consumeByte(b: *u8) i32 {
    if (consumable_data.len != 0) {
        b.* = consumable_data[0];
        consumable_data = consumable_data[1..];
        return 0;
    }
    return -1;
}

fn allocateFd() i32 {
    for (0..max_fds) |fd| {
        if (fd_to_file[fd] == null) {
            num_fds += 1;
            return @intCast(fd + reserved_system_fds);
        }
    }
    return -1;
}

fn initFd(fd: i32, @"type": i32, f: *File) void {
    if (fd >= reserved_system_fds) {
        fd_to_file[@as(usize, @intCast(fd)) - reserved_system_fds] = f;
        fd_to_file[@as(usize, @intCast(fd)) - reserved_system_fds].?.type = @"type";
        fd_to_file[@as(usize, @intCast(fd)) - reserved_system_fds].?.next = null;
        fd_to_file[@as(usize, @intCast(fd)) - reserved_system_fds].?.prev = null;
    }
}

fn mapFd(fd: i32) ?*File {
    if (fd >= reserved_system_fds and fd < max_fds + reserved_system_fds) {
        return fd_to_file[@as(usize, @intCast(fd)) - reserved_system_fds];
    }
    return null;
}

fn freeFd(fd: i32) i32 {
    if (fd >= reserved_system_fds and fd < max_fds + reserved_system_fds) {
        if (fd_to_file[@as(usize, @intCast(fd)) - reserved_system_fds] != null) {
            fd_to_file[@as(usize, @intCast(fd)) - reserved_system_fds] = null;
            num_fds -= 1;
            return 0;
        }
    }
    return -1;
}

const SocketFile = extern struct {
    base: File,
    addr: extern union {
        in6: std.c.sockaddr.in6,
        in: std.c.sockaddr.in,
    },
    len: std.c.socklen_t,
};

pub fn read(fd: std.c.fd_t, buf: [*]u8, count: usize) isize {
    if (fd < reserved_system_fds) {
        return std.c.read(fd, buf, count);
    }

    if (mapFd(fd)) |f| {
        std.c._errno().* = 0;
        if (f.type == @intFromEnum(FdType.socket)) {
            if (consumable_data.len == 0) {
                std.c._errno().* = @intCast(@intFromEnum(std.c.E.AGAIN));
                return -1;
            } else {
                var data_available: usize = consumable_data[0];
                consumable_data = consumable_data[1..];
                if (consumable_data.len < data_available) {
                    data_available = consumable_data.len;
                }
                if (count < data_available) {
                    data_available = count;
                }
                @memcpy(buf, consumable_data[0..data_available]);
                consumable_data = consumable_data[data_available..];
                return @intCast(data_available);
            }
        }

        if (f.type == @intFromEnum(FdType.event)) {
            @memset(buf[0..8], 1);
            return 8;
        }

        if (f.type == @intFromEnum(FdType.timer)) {
            @memset(buf[0..8], 1);
            return 8;
        }
    }

    return -1;
}

pub fn recv(
    sockfd: std.c.fd_t,
    arg1: ?*anyopaque,
    arg2: usize,
    _: c_int,
) if (builtin.os.tag == .windows) c_int else isize {
    return read(sockfd, @ptrCast(@alignCast(arg1)), arg2);
}

// TODO: ???
// pub fn sendto()

pub fn send(_: std.c.fd_t, _: *const anyopaque, len: usize, _: u32) isize {
    if (consumable_data.len != 0) {
        const scale = consumable_data[0];
        consumable_data = consumable_data[1..];
        const written: isize = @as(isize, @intFromFloat(@as(f32, @floatFromInt(scale)) / 255)) * @as(isize, @intCast(len));
        if (written == 0) {
            std.c._errno().* = @intCast(@intFromEnum(std.c.E.AGAIN));
        } else {
            std.c._errno().* = 0;
        }
        return written;
    } else {
        return -1;
    }
}

pub fn getpeername(sockfd: std.c.fd_t, noalias addr: *std.c.sockaddr, noalias len: *std.c.socklen_t) c_int {
    if (mapFd(sockfd)) |f| {
        if (f.type == @intFromEnum(FdType.socket)) {
            const sf: *SocketFile = @fieldParentPtr("base", f);
            @memcpy(std.mem.asBytes(addr)[0..sf.len], std.mem.asBytes(&sf.addr)[0..sf.len]);
            len.* = sf.len;
            return 0;
        }
    }
    return -1;
}

pub fn listen(_: std.c.fd_t, _: c_uint) c_int {
    var b: u8 = undefined;
    if (consumeByte(&b) != 0) {
        return -1;
    }
    if (b != 0) {
        return 0;
    }
    return -1;
}

var ai: std.c.addrinfo = undefined;

pub fn getaddrinfo(
    noalias _: ?[*:0]const u8,
    noalias _: ?[*:0]const u8,
    noalias hints: ?*const std.c.addrinfo,
    noalias res: *?*std.c.addrinfo,
) std.c.EAI {
    var hints_: *const std.c.addrinfo = undefined;
    var default_hints: std.c.addrinfo = undefined;
    if (hints) |h| {
        hints_ = h;
    } else {
        default_hints = std.mem.zeroInit(std.c.addrinfo, .{});
        hints_ = &default_hints;
    }

    var b: u8 = undefined;
    if (consumeByte(&b) != 0) {
        return @enumFromInt(-1);
    }
    ai.flags = hints_.flags;
    ai.socktype = hints_.socktype;
    ai.protocol = hints_.protocol;

    if (b > 127) {
        ai.family = std.c.AF.INET;
    } else {
        ai.family = std.c.AF.INET6;
    }

    if (b == 0) {
        ai.family = hints_.family;
    }

    ai.next = null;
    ai.canonname = null;

    ai.addrlen = 4;
    ai.addr = null;
    res.* = &ai;
    return @enumFromInt(0);
}

pub fn freeaddrinfo(_: *std.c.addrinfo) void {}

pub fn setsockopt(_: std.c.fd_t, _: i32, _: u32, _: ?*const anyopaque, _: std.c.socklen_t) c_int {
    return 0;
}

pub fn bind(_: std.c.fd_t, _: ?*const std.c.sockaddr, _: std.c.socklen_t) c_int {
    return 0;
}

pub fn fcntl(fd: std.c.fd_t, cmd: c_int, arg: c_int) c_int {
    if (fd < reserved_system_fds) {
        return std.c.fcntl(fd, cmd, arg);
    }
    return 0;
}

pub fn socket(domain: c_uint, _: c_uint, _: c_uint) c_int {
    if (domain != std.c.AF.INET and domain != std.c.AF.INET6) {
        return -1;
    }
    const fd = allocateFd();
    if (fd != -1) {
        const sf: *SocketFile = @ptrCast(@alignCast(std.c.malloc(@sizeOf(SocketFile))));
        initFd(fd, @intCast(@intFromEnum(FdType.socket)), @ptrCast(@alignCast(sf)));
    }
    return fd;
}

const EpollFile = extern struct {
    base: File,
    poll_set_head: ?*File,
    poll_set_tail: ?*File,
};

pub fn epoll_create1(_: c_uint) c_int {
    const fd = allocateFd();
    if (fd != -1) {
        const ef: *EpollFile = @ptrCast(@alignCast(std.c.malloc(@sizeOf(EpollFile))));
        ef.poll_set_head = null;
        ef.poll_set_tail = null;
        initFd(fd, @intFromEnum(FdType.epoll), &ef.base);
    }
    return @intCast(fd);
}

pub fn epoll_wait(epoll_fd: std.c.fd_t, events: [*]std.c.epoll_event, maxevents: c_uint, _: c_int) c_int {
    if (mapFd(epoll_fd)) |ef_base| {
        const ef: *EpollFile = @fieldParentPtr("base", ef_base);
        if (consumable_data.len != 0) {
            var ready_events: u32 = 0;
            var maybe_f = ef.poll_set_head;
            while (maybe_f) |f| : (maybe_f = f.next) {
                if (consumable_data.len == 0) {
                    break;
                }
                const ready_event = consumable_data[0] & f.epev.events;
                consumable_data = consumable_data[1..];
                if (ready_event != 0) {
                    if (ready_events < maxevents) {
                        events[ready_events] = f.epev;
                        events[ready_events].events = ready_event;
                        ready_events += 1;
                    } else {
                        break;
                    }
                }
            }
            return @intCast(ready_events);
        } else {
            teardown();

            var ready_events: u32 = 0;
            var maybe_f = ef.poll_set_head;
            while (maybe_f) |f| : (maybe_f = f.next) {
                if (f.type == @intFromEnum(FdType.socket)) {
                    if (ready_events < maxevents) {
                        events[ready_events] = f.epev;
                        events[ready_events].events = std.os.linux.EPOLL.ERR | std.os.linux.EPOLL.HUP;
                        ready_events += 1;
                    } else {
                        break;
                    }
                }
            }
            return @intCast(ready_events);
        }
    }
    return -1;
}

pub fn timerfd_settime(_: c_int, _: c_int, _: *const std.c.itimerspec, _: ?*std.c.itimerspec) c_int {
    return 0;
}

pub fn close(fd: std.c.fd_t) c_int {
    if (fd < reserved_system_fds) {
        return std.c.close(fd);
    }
    if (mapFd(fd)) |f| {
        if (f.type == @intFromEnum(FdType.epoll)) {
            std.c.free(f);
            return @intCast(freeFd(fd));
        } else if (f.type == @intFromEnum(FdType.timer)) {
            std.c.free(f);
            return @intCast(freeFd(fd));
        } else if (f.type == @intFromEnum(FdType.event)) {
            std.c.free(f);
            return @intCast(freeFd(fd));
        } else if (f.type == @intFromEnum(FdType.socket)) {
            std.c.free(f);
            return @intCast(freeFd(fd));
        }
    }
    return -1;
}

pub fn accept4(_: std.c.fd_t, noalias addr: ?*std.c.sockaddr, noalias _: ?*std.c.socklen_t, _: c_uint) c_int {
    var b: u8 = undefined;
    if (consumeByte(&b) != 0) {
        return -1;
    }
    if (b < 10) {
        const fd = allocateFd();
        if (fd != -1) {
            const sf: *SocketFile = @ptrCast(@alignCast(std.c.malloc(@sizeOf(SocketFile))));
            initFd(fd, @intFromEnum(FdType.socket), &sf.base);
            @memset(std.mem.asBytes(&sf.addr), 0);
            sf.len = @sizeOf(std.c.sockaddr.in6);
            sf.addr.in6.family = std.c.AF.INET6;
            if (b < 5) {
                @memset(std.mem.asBytes(&sf.addr), 0);
                sf.len = @sizeOf(std.c.sockaddr.in);
                sf.addr.in.family = std.c.AF.INET;
            }
            if (addr) |a| {
                @memcpy(std.mem.asBytes(@as(*std.c.sockaddr.storage, @ptrCast(@alignCast(a))))[0..sf.len], std.mem.asBytes(&sf.addr)[0..sf.len]);
            }
        }
        return fd;
    }
    return -1;
}

const EventFile = extern struct {
    base: File,
};

pub fn eventfd(_: c_uint, _: c_uint) c_int {
    const fd = allocateFd();
    if (fd != -1) {
        const ef: *EventFile = @ptrCast(@alignCast(std.c.malloc(@sizeOf(EventFile))));
        initFd(fd, @intFromEnum(FdType.event), &ef.base);
    }
    return @intCast(fd);
}

const TimerFile = extern struct {
    base: File,
};

pub fn timerfd_create(_: std.c.timerfd_clockid_t, _: c_int) c_int {
    const fd = allocateFd();
    if (fd != -1) {
        const tf: *TimerFile = @ptrCast(@alignCast(std.c.malloc(@sizeOf(TimerFile))));
        initFd(fd, @intFromEnum(FdType.timer), &tf.base);
    }
    return @intCast(fd);
}

pub fn epoll_ctl(epoll_fd: std.c.fd_t, op: c_uint, fd: std.c.fd_t, ev: ?*std.c.epoll_event) c_int {
    const ef: *EpollFile = blk: {
        if (mapFd(epoll_fd)) |tf| {
            break :blk @fieldParentPtr("base", tf);
        } else return -1;
    };

    const f: *File = blk: {
        if (mapFd(fd)) |tf| {
            break :blk tf;
        } else return -1;
    };

    if (op == std.os.linux.EPOLL.CTL_ADD) {
        if (ef.poll_set_head) |psh| {
            psh.prev = f;
            f.next = psh;
        } else {
            ef.poll_set_tail = f;
        }
        ef.poll_set_head = f;
        f.epev = ev.?.*;
    } else if (op == std.os.linux.EPOLL.CTL_MOD) {
        f.epev = ev.?.*;
    } else if (op == std.os.linux.EPOLL.CTL_DEL) {
        if (f.prev) |prev| {
            prev.next = f.next;
        } else {
            ef.poll_set_head = f.next;
        }
        if (f.next) |next| {
            next.prev = f.prev;
        } else {
            ef.poll_set_tail = f.prev;
        }
        f.prev = null;
        f.next = null;
    }
    f.epev.events |= std.os.linux.EPOLL.ERR | std.os.linux.EPOLL.HUP;
    return 0;
}

pub fn shutdown(_: std.c.fd_t, _: c_int) c_int {
    return 0;
}
