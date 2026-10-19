const builtin = @import("builtin");
const std = @import("std");

const epoll = @import("fuzzing/epoll.zig");

pub fn getpeername(fd: i32, noalias addr: *std.os.linux.sockaddr, noalias len: *std.os.linux.socklen_t) usize {
    if (comptime epoll.isEpollFuzzing()) {
        return epoll.getpeername(fd, addr, len);
    } else {
        return std.os.linux.getpeername(fd, addr, len);
    }
}

pub fn read(fd: i32, buf: [*]u8, count: usize) usize {
    if (comptime epoll.isEpollFuzzing()) {
        return epoll.read(fd, buf, count);
    } else {
        return std.os.linux.read(fd, buf, count);
    }
}
pub fn epoll_wait(epoll_fd: i32, events: [*]std.os.linux.epoll_event, maxevents: u32, timeout: i32) usize {
    if (comptime epoll.isEpollFuzzing()) {
        return epoll.epoll_wait(epoll_fd, events, maxevents, timeout);
    } else {
        return std.os.linux.epoll_wait(epoll_fd, events, maxevents, timeout);
    }
}

pub fn epoll_create1(flags: usize) usize {
    if (comptime epoll.isEpollFuzzing()) {
        return epoll.epoll_create1(flags);
    } else {
        return std.os.linux.epoll_create1(flags);
    }
}

pub fn timerfd_settime(fd: i32, flags: std.os.linux.TFD.TIMER, new_value: *const std.os.linux.itimerspec, old_value: ?*std.os.linux.itimerspec) usize {
    if (comptime epoll.isEpollFuzzing()) {
        return epoll.timerfd_settime(fd, flags, new_value, old_value);
    } else {
        return std.os.linux.timerfd_settime(fd, flags, new_value, old_value);
    }
}

pub fn close(fd: std.os.linux.fd_t) usize {
    if (comptime epoll.isEpollFuzzing()) {
        return epoll.linux_close(fd);
    } else {
        return std.os.linux.close(fd);
    }
}

pub fn eventfd(count: u32, flags: u32) usize {
    if (comptime epoll.isEpollFuzzing()) {
        return epoll.eventfd(count, flags);
    } else {
        return std.os.linux.eventfd(count, flags);
    }
}

pub fn timerfd_create(clockid: std.os.linux.timerfd_clockid_t, flags: std.os.linux.TFD) usize {
    if (comptime epoll.isEpollFuzzing()) {
        return epoll.timerfd_create(clockid, flags);
    } else {
        return std.os.linux.timerfd_create(clockid, flags);
    }
}

pub fn epoll_ctl(epoll_fd: i32, op: u32, fd: i32, ev: ?*std.os.linux.epoll_event) usize {
    if (comptime epoll.isEpollFuzzing()) {
        return epoll.epoll_ctl(epoll_fd, op, fd, ev);
    } else {
        return std.os.linux.epoll_ctl(epoll_fd, op, fd, ev);
    }
}

pub fn shutdown(fd: i32, how: i32) usize {
    if (comptime epoll.isEpollFuzzing()) {
        return epoll.linux_shutdown(fd, how);
    } else {
        return std.os.linux.shutdown(fd, how);
    }
}
