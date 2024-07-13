const build_opts = @import("build_opts");
const builtin = @import("builtin");
const constants = @import("../../constants.zig");
const internal = @import("../internal.zig");
const std = @import("std");

const EXT_ALIGNMENT = constants.EXT_ALIGNMENT;
const RECV_BUFFER_LENGTH = constants.RECV_BUFFER_LENGTH;
const RECV_BUFFER_PADDING = constants.RECV_BUFFER_PADDING;
const InternalAsync = internal.InternalAsync;
const InternalLoopData = @import("../loop_data.zig").InternalLoopData;

const Allocator = std.mem.Allocator;
const InternalCallback = internal.InternalCallback;
const PollType = internal.PollType;
const SocketDescriptor = internal.SocketDescriptor;
const StructField = std.builtin.Type.StructField;
const Timer = internal.Timer;

pub const SOCKET_READABLE = switch (build_opts.event_loop_lib) {
    .epoll => std.os.linux.EPOLL.IN,
    else => 1,
};

pub const SOCKET_WRITABLE = switch (build_opts.event_loop_lib) {
    .epoll => std.os.linux.EPOLL.OUT,
    else => 1,
};

pub const NativePoll = if (build_opts.event_loop_lib == .epoll) std.os.linux.epoll_event else std.posix.Kevent;

pub const Loop = struct {
    data: InternalLoopData align(EXT_ALIGNMENT),
    num_polls: u64,
    num_ready_polls: u64,
    current_ready_poll: u64,
    fd: i32,
    ready_polls: [1024]NativePoll,

    pub fn init(
        allocator: Allocator,
        hint: ?*anyopaque,
        wakeup_cb: *const fn (loop: *Loop) anyerror!void,
        pre_cb: *const fn (loop: *Loop) anyerror!void,
        post_cb: *const fn (loop: *Loop) anyerror!void,
        ext_size: u32,
    ) !*Loop {
        _ = hint; // autofix
        var res: *Loop = @ptrCast(@alignCast(try allocator.alloc(u8, @sizeOf(Loop) + ext_size)));
        errdefer allocator.free(std.mem.asBytes(res));
        res.num_polls = 0;
        res.num_ready_polls = 0;
        res.current_ready_poll = 0;

        if (build_opts.event_loop_lib == .epoll) {
            res.fd = try std.posix.epoll_create1(std.os.linux.EPOLL.CLOEXEC);
        } else {
            res.fd = try std.posix.kqueue();
        }
        try res.internalLoopDataInit(allocator, wakeup_cb, pre_cb, post_cb);
        return res;
    }

    pub fn internalLoopDataInit(
        self: *Loop,
        allocator: Allocator,
        wakeup_cb: *const fn (loop: *Loop) anyerror!void,
        pre_cb: *const fn (loop: *Loop) anyerror!void,
        post_cb: *const fn (loop: *Loop) anyerror!void,
    ) !void {
        self.data.sweep_timer = try self.createTimer(allocator, true, 0);
        // TODO: errdefer close file handle
        self.data.recv_buf = try allocator.alloc(u8, RECV_BUFFER_LENGTH + RECV_BUFFER_PADDING * 2);
        errdefer allocator.free(self.data.recv_buf);
        self.data.ssl_data = null;
        self.data.head = null;
        self.data.iterator = null;
        self.data.closed_head = null;
        self.data.low_prio_head = null;
        self.data.low_prio_budget = 0;
        self.data.pre_cb = pre_cb;
        self.data.post_cb = post_cb;
        self.data.last_write_failed = false;
        self.data.iteration_nr = 0;
        self.data.wakeup_async = try self.internalCreateAsync(allocator, true, 0);
        Loop.internalAsyncSet(self.data.wakeup_async.?, @ptrCast(@alignCast(wakeup_cb)));
    }

    pub fn createTimer(self: *Loop, allocator: Allocator, fallthrough: bool, ext_size: u32) !*Timer {
        switch (build_opts.event_loop_lib) {
            .epoll => {
                var p = try Poll.create(allocator, self, fallthrough, @sizeOf(InternalCallback) + ext_size);
                errdefer p.destroy(allocator);
                const timerfd = try std.posix.timerfd_create(std.os.linux.CLOCK.REALTIME, .{ .NONBLOCK = true, .CLOEXEC = true });
                errdefer std.posix.close(timerfd);
                p.init(timerfd, .callback);
                const cb: *InternalCallback = @ptrCast(@alignCast(p));
                cb.loop = self;
                cb.cb_expects_the_loop = false;
                cb.leave_poll_ready = false;
                return @ptrCast(@alignCast(cb));
            },
            else => {
                const buf = try allocator.alloc(u8, @sizeOf(InternalCallback) + ext_size);
                errdefer allocator.free(buf);
                const cb: *InternalCallback = @ptrCast(@alignCast(buf.ptr));
                cb.loop = self;
                cb.cb_expects_the_loop = false;
                cb.leave_poll_ready = false;
                // Bug: internalPollSetType does not SET the type, it only CHANGES it
                cb.p.state.poll_type = .callback;
                internalPollSetType(@ptrCast(@alignCast(cb)), .callback);
                if (!fallthrough) {
                    self.num_polls += 1;
                }

                return @ptrCast(@alignCast(cb));
            },
        }
    }

    pub fn internalCreateAsync(self: *Loop, allocator: Allocator, fallthrough: bool, ext_size: u32) !*InternalAsync {
        switch (build_opts.event_loop_lib) {
            .epoll => {
                const p = try Poll.create(allocator, self, fallthrough, @sizeOf(InternalCallback) + ext_size);
                p.init(std.posix.eventfd(0, std.os.linux.EFD.NONBLOCK | std.os.linux.EFD.CLO), .callback);
                const cb: *InternalCallback = @ptrCast(@alignCast(p));
                cb.loop = self;
                cb.cb_expects_the_loop = true;
                cb.leave_poll_ready = false;
                return @ptrCast(@alignCast(cb));
            },
            else => {
                const buf = try allocator.alloc(u8, @sizeOf(InternalCallback) + ext_size);
                errdefer allocator.free(buf);
                const cb: *InternalCallback = @ptrCast(@alignCast(buf.ptr));
                cb.loop = self;
                cb.cb_expects_the_loop = true;
                cb.leave_poll_ready = false;
                // Bug: internalPollSetType does not SET the type, it only CHANGES it
                cb.p.state.poll_type = .polling_in;
                internalPollSetType(@ptrCast(@alignCast(cb)), .callback);
                if (!fallthrough) {
                    self.num_polls += 1;
                }
                return @ptrCast(@alignCast(cb));
            },
        }
    }

    pub fn internalAsyncSet(a: *InternalAsync, cb: *const fn (a_: *InternalAsync) anyerror!void) void {
        const internal_cb: *InternalCallback = @ptrCast(@alignCast(a));
        switch (build_opts.event_loop_lib) {
            .epoll => {
                internal_cb.cb = @ptrCast(@alignCast(cb));
                @as(*Poll, @ptrCast(@alignCast(a))).start(internal_cb.loop, SOCKET_READABLE);
            },
            else => internal_cb.cb = @ptrCast(@alignCast(cb)),
        }
    }
};

pub const Poll = struct {
    state: packed struct {
        fd: i28,
        poll_type: PollType,
    } align(EXT_ALIGNMENT),

    /// Returns the type of poll.
    pub fn internalPollType(self: *Poll) PollType {
        return @enumFromInt(@intFromEnum(self.state.poll_type) & 3);
    }

    pub fn start(self: *Poll, loop: *Loop, events_: u32) !void {
        self.state.poll_type = @intFromEnum(self.internalPollType()) | (if (events & SOCKET_READABLE) @intFromEnum(PollType.polling_in) else 0) | (if (events & SOCKET_WRITABLE) @intFromEnum(PollType.polling_out) else 0);

        switch (build_opts.event_loop_lib) {
            .epoll => {
                var event: std.os.linux.epoll_event = undefined;
                event.events = events_;
                event.data.ptr = @intFromPtr(self);
                try std.posix.epoll_ctl(loop.fd, std.os.linux.EPOLL.CTL_ADD, self.state.fd, &event);
            },
            else => _ = try kqueueChange(loop.fd, self.state.fd, 0, events_, self),
        }
    }

    pub fn fd(self: *Poll) SocketDescriptor {
        return self.state.fd;
    }

    pub fn create(allocator: Allocator, loop: *Loop, fallthrough: bool, ext_size: u32) !*Poll {
        if (!fallthrough) loop.num_polls += 1;
        const buf = try allocator.alloc(u8, @sizeOf(Poll) + ext_size);
        return @as(*Poll, @ptrCast(@alignCast(buf.ptr)));
    }

    pub fn destroy(self: *Poll, allocator: Allocator) void {
        // TODO(cryptodeal): maybe close fd here??
        allocator.free(std.mem.asBytes(self));
        self.* = undefined;
    }

    pub fn init(self: *Poll, fd_: SocketDescriptor, poll_type: PollType) void {
        self.state.fd = @intCast(fd_);
        self.state.poll_type = poll_type;
    }

    pub fn events(self: *Poll) u32 {
        return ((if ((@intFromEnum(self.state.poll_type) & @intFromEnum(PollType.polling_in)) == 1) @as(u32, SOCKET_READABLE) else 0) | (if ((@intFromEnum(self.state.poll_type) & @intFromEnum(PollType.polling_out)) == 1) @as(u32, SOCKET_WRITABLE) else 0));
    }

    pub fn change(self: *Poll, loop: *Loop, events_: u32) !void {
        const old_events = self.events();
        if (old_events != events_) {
            self.state.poll_type = @enumFromInt(@intFromEnum(self.internalPollType()) | (if ((events_ & SOCKET_READABLE) == 1) @intFromEnum(PollType.polling_in) else 0) | (if ((events_ & SOCKET_WRITABLE) == 1) @intFromEnum(PollType.polling_out) else 0));
            switch (build_opts.event_loop_lib) {
                .epoll => {
                    var event: std.os.linux.epoll_event = undefined;
                    event.events = events_;
                    event.data.ptr = @intFromPtr(self);
                    try std.posix.epoll_ctl(loop.fd, std.os.linux.EPOLL.CTL_MOD, self.state.fd, &event);
                },
                else => _ = try kqueueChange(loop.fd, self.state.fd, old_events, events_, self),
            }
            // possibly need to set removed polls to null in pending ready poll list
            // internalLoopUpdatePendingReadyPolls(loop, self, self, old_events, events)

        }
    }
};

fn internalPollSetType(p: *Poll, poll_type: PollType) void {
    p.state.poll_type = @enumFromInt(@intFromEnum(poll_type) | (@intFromEnum(p.state.poll_type) & 12));
}

fn kqueueChange(kqfd: std.posix.fd_t, fd: std.posix.fd_t, old_events: u32, new_events: u32, user_data: ?*anyopaque) !usize {
    switch (build_opts.event_loop_lib) {
        .kqueue => {
            var change_list: [2]std.posix.Kevent = undefined;
            var len: u8 = 0;

            // Do they differ in readable?
            if ((new_events & SOCKET_READABLE) != (old_events & SOCKET_READABLE)) {
                change_list[len] = .{
                    .ident = @intCast(fd),
                    .filter = std.c.EVFILT_READ,
                    .flags = if ((new_events & SOCKET_READABLE) == 1) std.c.EV_ADD else std.c.EV_DELETE,
                    .fflags = 0,
                    .data = 0,
                    .udata = @intFromPtr(user_data),
                };
                len += 1;
            }

            // Do they differ in writable?
            if ((new_events & SOCKET_WRITABLE) != (old_events & SOCKET_WRITABLE)) {
                change_list[len] = .{
                    .ident = @intCast(fd),
                    .filter = std.c.EVFILT_WRITE,
                    .flags = if ((new_events & SOCKET_WRITABLE) == 1) std.c.EV_ADD else std.c.EV_DELETE,
                    .fflags = 0,
                    .data = 0,
                    .udata = @intFromPtr(user_data),
                };
                len += 1;
            }

            return std.posix.kevent(kqfd, &change_list, &.{}, null);
        },
        else => return error.UnsupportedEventLoop,
    }
}
