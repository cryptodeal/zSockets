const std = @import("std");
const constants = @import("constants.zig");
const Extension = @import("../../extension.zig");
const LoopData = @import("../../internal/loop_data.zig");
const Poll = @import("poll.zig");
const build_opts = @import("build_opts");
const loop = @import("../../loop.zig");

const Self = @This();

data: LoopData,
polls_count: i32 = 0,
ready_polls_count: u32 = 0,
current_ready_poll: u32 = 0,
fd: std.posix.fd_t,
ready_polls: if (build_opts.event_backend == .epoll) [1024]std.os.linux.epoll_event else [1024]std.posix.Kevent = undefined,
ext: Extension = .{},

fn getReadyPoll(self: *Self, index: u32) ?*Poll {
    if (build_opts.event_backend == .epoll) {
        return @ptrFromInt(self.ready_polls[index].data.ptr);
    } else {
        return @ptrFromInt(self.ready_polls[index].udata);
    }
}

fn setReadyPoll(self: *Self, index: u32, poll: ?*Poll) void {
    if (build_opts.event_backend == .epoll) {
        self.ready_polls[index].data.ptr = @intFromPtr(poll);
    } else {
        self.ready_polls[index].udata = @intFromPtr(poll);
    }
}

// unused `hint: ?*anyopaque`
pub fn init(allocator: std.mem.Allocator, io: std.Io, _: ?*anyopaque, wakeup_cb: *const fn (std.mem.Allocator, std.Io, *Self) anyerror!void, pre_cb: *const fn (std.mem.Allocator, std.Io, *Self) anyerror!void, post_cb: *const fn (std.mem.Allocator, std.Io, *Self) anyerror!void, comptime MaybeT: ?type) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .data = undefined,
        .fd = if (build_opts.event_backend == .epoll) @intCast(std.os.linux.epoll_create1(std.os.linux.EPOLL.CLOEXEC)) else std.c.kqueue(),
        .ext = try Extension.init(allocator, MaybeT),
    };
    self.data = try LoopData.init(allocator, io, self, wakeup_cb, pre_cb, post_cb);
    return self;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.data.deinit(allocator);
    _ = std.c.close(self.fd);
    self.ext.deinit(allocator);
    allocator.destroy(self);
}

pub fn run(self: *Self, allocator: std.mem.Allocator, io: std.Io) !void {
    loop.integrate(self);
    while (self.polls_count != 0) {
        try loop.pre(allocator, io, self);
        if (build_opts.event_backend == .epoll) {
            self.ready_polls_count = @intCast(std.os.linux.epoll_wait(self.fd, &self.ready_polls, 1024, -1));
        } else {
            // added timeout (whereas none in uSockets impl)
            const timeout: std.c.timespec = .{ .sec = 0, .nsec = if (self.polls_count > 2) 500000 else 5000000 };
            self.ready_polls_count = @intCast(std.c.kevent(self.fd, &.{}, 0, &self.ready_polls, 1024, &timeout));
        }
        self.current_ready_poll = 0;
        while (self.current_ready_poll < self.ready_polls_count) : (self.current_ready_poll += 1) {
            if (self.getReadyPoll(self.current_ready_poll)) |p| {
                var events: u32 = undefined;
                var err: u32 = undefined;
                if (build_opts.event_backend == .epoll) {
                    events = self.ready_polls[self.current_ready_poll].events;
                    err = self.ready_polls[self.current_ready_poll].events & (std.os.linux.EPOLL.ERR | std.os.linux.EPOLL.HUP);
                } else {
                    events = constants.socket_readable;
                    if (self.ready_polls[self.current_ready_poll].filter == std.c.EVFILT.WRITE) {
                        events = constants.socket_writable;
                    }
                    err = self.ready_polls[self.current_ready_poll].flags & (std.c.EV.ERROR | std.c.EV.EOF);
                }
                events &= p.events();
                if (events != 0 or err != 0) {
                    try loop.internalDispatchReadyPoll(allocator, io, p, err, events);
                }
            }
        }
        try loop.post(allocator, io, self);
    }
}

pub fn updatePendingReadyPolls(self: *Self, old_poll: ?*Poll, new_poll: ?*Poll, _: u32, _: u32) void {
    var num_entries_possibly_remaining: u32 = if (build_opts.event_backend == .epoll) 1 else 2;
    var i = self.current_ready_poll;
    while (i < self.ready_polls_count and num_entries_possibly_remaining != 0) : (i += 1) {
        // TODO: need to verify that `old_poll` can be null
        if (self.getReadyPoll(i) == old_poll) {
            self.setReadyPoll(i, new_poll);
            num_entries_possibly_remaining -= 1;
        }
    }
}

pub fn getExt(self: *Self, comptime T: type) ?*T {
    return @ptrCast(@alignCast(self.ext.ptr));
}
