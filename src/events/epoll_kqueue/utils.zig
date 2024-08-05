const std = @import("std");
const zs = @import("../../zsockets.zig");

pub usingnamespace @import("../../loop.zig");

pub fn kqueueChange(kqfd: std.c.fd_t, fd_: std.c.fd_t, old_events: u32, new_events: u32, user_data: ?*anyopaque) !usize {
    var change_list: [2]std.c.Kevent = undefined;
    var len: u8 = 0;
    // Do they differ in readable?
    if ((new_events & zs.SOCKET_READABLE) != (old_events & zs.SOCKET_READABLE)) {
        change_list[len] = .{
            .ident = @intCast(fd_),
            .filter = std.c.EVFILT_READ,
            .flags = if ((new_events & zs.SOCKET_READABLE) != 0) std.c.EV_ADD else std.c.EV_DELETE,
            .fflags = 0,
            .data = 0,
            .udata = @intFromPtr(user_data),
        };
        len += 1;
    }

    // Do they differ in writable?
    if ((new_events & zs.SOCKET_WRITABLE) != (old_events & zs.SOCKET_WRITABLE)) {
        change_list[len] = .{
            .ident = @intCast(fd_),
            .filter = std.c.EVFILT_WRITE,
            .flags = if ((new_events & zs.SOCKET_WRITABLE) != 0) std.c.EV_ADD else std.c.EV_DELETE,
            .fflags = 0,
            .data = 0,
            .udata = @intFromPtr(user_data),
        };
        len += 1;
    }

    return @intCast(std.c.kevent(kqfd, change_list[0..len].ptr, len, change_list[0..0].ptr, 0, null));
}
