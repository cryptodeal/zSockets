const build_opts = @import("build_opts");
const internal = @import("../internal.zig");
const loop_ = @import("../loop.zig");
const std = @import("std");

const Extensions = @import("../zsockets.zig").Extensions;

const Allocator = std.mem.Allocator;
const EXT_ALIGNMENT = internal.EXT_ALIGNMENT;
const InternalAsync = internal.InternalAsync;
const InternalCallback = internal.InternalCallback;
const internalDispatchReadyPoll = loop_.internalDispatchReadyPoll;
const internalLoopPost = loop_.internalLoopPost;
const internalLoopPre = loop_.internalLoopPre;
const internalTimerSweep = loop_.internalTimerSweep;
const PollType = internal.PollType;
const RECV_BUFFER_LENGTH = internal.RECV_BUFFER_LENGTH;
const RECV_BUFFER_PADDING = internal.RECV_BUFFER_PADDING;
const SocketDescriptor = internal.SocketDescriptor;
const TIMEOUT_GRANULARITY = internal.TIMEOUT_GRANULARITY;
const Timer = internal.Timer;

pub const SOCKET_READABLE = switch (build_opts.event_loop_lib) {
    .epoll => std.os.EPOLL.IN,
    else => 1,
};

pub const SOCKET_WRITABLE = switch (build_opts.event_loop_lib) {
    .epoll => std.os.EPOLL.OUT,
    else => 2,
};

pub fn Loop(comptime ssl: bool, comptime extensions: Extensions) type {
    const LoopExt = extensions.loop;
    switch (build_opts.event_loop_lib) {
        .epoll => return struct {
            const Self = @This();
            pub const Poll = PollT(extensions.poll, Self);
            pub const Socket = @import("../socket.zig").Socket(ssl, extensions.socket, extensions.socket_ctx, Self, Poll);
            const LoopData = @import("../loop.zig").LoopData(Self, Socket, Socket.Context);

            data: LoopData align(EXT_ALIGNMENT),
            num_polls: u64,
            num_ready_polls: u64,
            current_ready_poll: u64,
            fd: i32,
            ready_polls: [1024]std.os.epoll_event = undefined,
            ext: ?LoopExt = null,

            pub fn init(
                allocator: Allocator,
                _: ?*anyopaque,
                wakeup_cb: *const fn (allocator: Allocator, loop: *Self) anyerror!void,
                pre_cb: *const fn (allocator: Allocator, loop: *Self) anyerror!void,
                post_cb: *const fn (allocator: Allocator, loop: *Self) anyerror!void,
            ) !*Self {
                const res: *Self = try allocator.create(Self);
                res.* = .{
                    .num_polls = 0,
                    .num_ready_polls = 0,
                    .current_ready_poll = 0,
                    .fd = try std.posix.epoll_create1(std.os.EPOLL.CLOEXEC),
                };
                try res.internalLoopDataInit(allocator, wakeup_cb, pre_cb, post_cb);
                return res;
            }

            fn internalLoopDataInit(
                self: *Self,
                allocator: Allocator,
                wakeup_cb: *const fn (allocator: Allocator, loop: *Self) anyerror!void,
                pre_cb: *const fn (allocator: Allocator, loop: *Self) anyerror!void,
                post_cb: *const fn (allocator: Allocator, loop: *Self) anyerror!void,
            ) !void {
                const sweep_timer = try self.createTimer(allocator, true);
                // TODO(cryptodeal): errdefer close file handle
                const rec_buf = try allocator.alloc(u8, RECV_BUFFER_LENGTH + RECV_BUFFER_PADDING * 2);
                errdefer allocator.free(rec_buf);
                self.data = .{
                    .sweep_timer = sweep_timer,
                    .ssl_data = null,
                    .head = null,
                    .iterator = null,
                    .closed_head = null,
                    .low_priority_head = null,
                    .low_priority_budget = 0,
                    .pre_cb = pre_cb,
                    .post_cb = post_cb,
                    .last_write_failed = false,
                    .iteration_nr = 0,
                    .wakeup_async = try self.internalCreateAsync(allocator, true),
                };
                Self.internalAsyncSet(self.data.wakeup_async.?, @ptrCast(@alignCast(wakeup_cb)));
            }

            pub fn internalAsyncSet(a: *InternalAsync, cb: *const fn (a_: *InternalAsync) anyerror!void) void {
                const internal_cb: *InternalCallback(Poll, Self) = @ptrCast(@alignCast(a));
                internal_cb.cb = @ptrCast(@alignCast(cb));
                @as(*Poll, @ptrCast(@alignCast(a))).start(internal_cb.loop, SOCKET_READABLE);
            }

            pub fn createTimer(self: *Self, allocator: Allocator, fallthrough: bool) !*Timer {
                const timerfd = try std.posix.timerfd_create(std.os.CLOCK.REALTIME, .{ .NONBLOCK = true, .CLOEXEC = true });
                errdefer std.posix.close(timerfd);
                var p = try Poll.init(allocator, self, fallthrough, timerfd, .callback);
                errdefer p.destroy(allocator);
                const cb: *InternalCallback(Poll, Self) = @ptrCast(@alignCast(p));
                cb.loop = self;
                cb.cb_expects_the_loop = false;
                cb.leave_poll_ready = false;
                return @ptrCast(@alignCast(cb));
            }

            fn internalCreateAsync(self: *Self, allocator: Allocator, fallthrough: bool) !*InternalAsync {
                const p = try Poll.init(allocator, self, fallthrough, try std.posix.eventfd(0, std.os.EFD.NONBLOCK | std.os.EFD.CLO), .callback);
                const cb: *InternalCallback(Poll, Self) = @ptrCast(@alignCast(p));
                cb.loop = self;
                cb.cb_expects_the_loop = true;
                cb.leave_poll_ready = false;
            }

            inline fn getReadyPoll(loop: *Self, index: anytype) ?*Poll {
                return @ptrFromInt(loop.ready_polls[index].data.ptr);
            }

            inline fn setReadyPoll(loop: *Self, index: anytype, poll: ?*Poll) void {
                loop.ready_polls[index].data.ptr = @intFromPtr(poll);
            }

            pub fn updatePendingReadyPolls(self: *Self, old_poll: *Poll, new_poll: ?*Poll, _: u32, _: u32) void {
                var num_entries_possibly_left: u8 = 1;
                var i: usize = self.current_ready_poll;
                while (i < self.num_ready_polls and num_entries_possibly_left != 0) : (i += 1) {
                    if (getReadyPoll(self, i)) |ready| {
                        if (ready == old_poll) {
                            setReadyPoll(self, i, new_poll);
                            num_entries_possibly_left -= 1;
                        }
                    }
                }
            }

            fn sweepTimerCb(allocator: Allocator, cb: *InternalCallback(Poll, Self)) !void {
                return internalTimerSweep(allocator, cb.loop);
            }

            pub fn timerSet(t: *Timer, cb: *const fn (allocator: Allocator, t: *Timer) anyerror!void, ms: isize, repeat_ms: isize) !void {
                const internal_cb: *InternalCallback(Poll, Self) = @ptrCast(@alignCast(t));
                internal_cb.cb = @ptrCast(cb);

                const timer_spec: std.os.itimerspec = .{
                    .it_interval = .{
                        .tv_sec = @divTrunc(repeat_ms, 1000),
                        .tv_nsec = @rem(repeat_ms, 1000) * 1000000,
                    },
                    .it_value = .{
                        .tv_sec = @divTrunc(ms, 1000),
                        .tv_nsec = @rem(ms, 1000) * 1000000,
                    },
                };
                try std.posix.timerfd_settime(@as(*Poll, @ptrCast(@alignCast(t))).fd(), 0, &timer_spec, null);
                try @as(*Poll, @ptrCast(@alignCast(t))).start(internal_cb.loop, SOCKET_READABLE);
            }

            pub fn loopIntegrate(loop: *Self) !void {
                return timerSet(
                    loop.data.sweep_timer.?,
                    @ptrCast(&sweepTimerCb),
                    TIMEOUT_GRANULARITY * 1000,
                    TIMEOUT_GRANULARITY * 1000,
                );
            }

            pub fn run(self: *Self, allocator: Allocator) !void {
                try loopIntegrate(self);

                while (self.num_polls != 0) {
                    // emit pre-callback
                    try internalLoopPre(allocator, self);

                    // fetch ready polls
                    // TODO: finish implementation
                    self.num_ready_polls = try std.posix.epoll_wait(self.fd, self.ready_polls[0..self.num_polls], -1);
                    self.current_ready_poll = 0;
                    while (self.current_ready_poll < self.num_ready_polls) : (self.current_ready_poll += 1) {
                        const maybe_poll: ?*Poll = getReadyPoll(self, self.current_ready_poll);
                        if (maybe_poll) |poll| {
                            var events: u32 = self.ready_polls[self.current_ready_poll].events;
                            const err: u32 = self.ready_polls[self.current_ready_polls].events & (std.os.EPOLL.ERR | std.os.EPOLL.HUP);
                            events &= poll.events();
                            if (events != 0 or err != 0) {
                                try internalDispatchReadyPoll(allocator, poll, err, events);
                            }
                        }
                    }
                    try internalLoopPost(allocator, self);
                }
            }
        },
        else => return struct {
            const Self = @This();
            pub const Poll = PollT(extensions.poll, Self);
            pub const Socket = @import("../socket.zig").Socket(ssl, extensions.socket, extensions.socket_ctx, Self, Poll);
            const LoopData = @import("../loop.zig").LoopData(Self, Socket, Socket.Context);

            data: LoopData align(EXT_ALIGNMENT),
            num_polls: u64,
            num_ready_polls: u64,
            current_ready_poll: u64,
            fd: i32,
            ready_polls: [1024]std.posix.Kevent = undefined,
            ext: ?LoopExt = null,

            pub fn init(
                allocator: Allocator,
                _: ?*anyopaque,
                wakeup_cb: *const fn (allocator: Allocator, loop: *Self) anyerror!void,
                pre_cb: *const fn (allocator: Allocator, loop: *Self) anyerror!void,
                post_cb: *const fn (allocator: Allocator, loop: *Self) anyerror!void,
            ) !*Self {
                const res: *Self = try allocator.create(Self);
                res.* = .{
                    .data = undefined,
                    .num_polls = 0,
                    .num_ready_polls = 0,
                    .current_ready_poll = 0,
                    .fd = try std.posix.kqueue(),
                };
                try res.internalLoopDataInit(allocator, wakeup_cb, pre_cb, post_cb);
                return res;
            }

            pub fn deinit(self: *Self, allocator: Allocator) void {
                loop_.internalLoopDataFree(allocator, self) catch unreachable;
                _ = std.c.close(self.fd);
                allocator.destroy(self);
            }

            fn internalLoopDataInit(
                self: *Self,
                allocator: Allocator,
                wakeup_cb: *const fn (allocator: Allocator, loop: *Self) anyerror!void,
                pre_cb: *const fn (allocator: Allocator, loop: *Self) anyerror!void,
                post_cb: *const fn (allocator: Allocator, loop: *Self) anyerror!void,
            ) !void {
                const sweep_timer = try self.createTimer(allocator, true);
                // TODO(cryptodeal): errdefer close file handle
                const recv_buf = try allocator.alloc(u8, RECV_BUFFER_LENGTH + RECV_BUFFER_PADDING * 2);
                errdefer allocator.free(recv_buf);
                self.data = .{
                    .sweep_timer = sweep_timer,
                    .recv_buf = recv_buf,
                    .ssl_data = null,
                    .head = null,
                    .iterator = null,
                    .closed_head = null,
                    .low_priority_head = null,
                    .low_priority_budget = 0,
                    .pre_cb = pre_cb,
                    .post_cb = post_cb,
                    .last_write_failed = false,
                    .iteration_nr = 0,
                    .wakeup_async = try self.internalCreateAsync(allocator, true),
                };
                try Self.internalAsyncSet(self.data.wakeup_async.?, @ptrCast(@alignCast(wakeup_cb)));
            }

            pub fn internalAsyncSet(a: *InternalAsync, cb: *const fn (a_: *InternalAsync) anyerror!void) !void {
                const internal_cb: *InternalCallback(Poll, Self) = @ptrCast(@alignCast(a));
                internal_cb.cb = @ptrCast(@alignCast(cb));
            }

            pub fn createTimer(self: *Self, allocator: Allocator, fallthrough: bool) !*Timer {
                const cb = try allocator.create(InternalCallback(Poll, Self));
                cb.loop = self;
                cb.cb_expects_the_loop = true;
                cb.leave_poll_ready = false;
                // Bug: internalPollSetType does not SET the type, it only CHANGES it
                cb.p.state.poll_type = .polling_in;
                @as(*Poll, @ptrCast(@alignCast(cb))).setPollType(.callback);
                if (!fallthrough) {
                    self.num_polls += 1;
                }
                return @ptrCast(@alignCast(cb));
            }

            pub fn destroyTimer(allocator: Allocator, timer: *Timer) !void {
                const internal_cb: *InternalCallback(Poll, Self) = @ptrCast(@alignCast(timer));
                // add a triggered oneshot event
                const kevent: std.posix.Kevent = .{
                    .ident = @intFromPtr(internal_cb),
                    .filter = std.c.EVFILT_TIMER,
                    .flags = std.c.EV_DELETE,
                    .fflags = 0,
                    .data = 0,
                    .udata = @intFromPtr(internal_cb),
                };
                _ = try std.posix.kevent(internal_cb.loop.fd, &.{kevent}, &.{}, null);
                @as(*Poll, @ptrCast(@alignCast(timer))).deinit(allocator, internal_cb.loop);
            }

            fn internalCreateAsync(self: *Self, allocator: Allocator, fallthrough: bool) !*InternalAsync {
                const cb = try allocator.create(InternalCallback(Poll, Self));
                cb.loop = self;
                cb.cb_expects_the_loop = true;
                cb.leave_poll_ready = false;
                // Bug: internalPollSetType does not SET the type, it only CHANGES it
                cb.p.state.poll_type = .polling_in;
                @as(*Poll, @ptrCast(@alignCast(cb))).setPollType(.callback);
                if (!fallthrough) {
                    self.num_polls += 1;
                }
                return @ptrCast(@alignCast(cb));
            }

            pub fn internalCloseAsync(allocator: Allocator, a: *InternalAsync) !void {
                const internal_cb: *InternalCallback(Poll, Self) = @ptrCast(@alignCast(a));
                // add a triggered oneshot event
                const kevent: std.posix.Kevent = .{
                    .ident = @intFromPtr(internal_cb),
                    .filter = std.c.EVFILT_TIMER,
                    .flags = std.c.EV_DELETE,
                    .fflags = 0,
                    .data = 0,
                    .udata = @intFromPtr(internal_cb),
                };
                _ = try std.posix.kevent(internal_cb.loop.fd, &.{kevent}, &.{}, null);
                @as(*Poll, @ptrCast(@alignCast(a))).deinit(allocator, internal_cb.loop);
            }

            inline fn getReadyPoll(loop: *Self, index: anytype) ?*Poll {
                return @ptrFromInt(loop.ready_polls[index].udata);
            }

            inline fn setReadyPoll(loop: *Self, index: anytype, poll: ?*anyopaque) void {
                loop.ready_polls[index].udata = @intFromPtr(poll);
            }

            pub fn updatePendingReadyPolls(self: *Self, old_poll: *Poll, new_poll: ?*Poll, _: u32, _: u32) void {
                var num_entries_possibly_left: u8 = 2;
                var i: usize = self.current_ready_poll;
                while (i < self.num_ready_polls and num_entries_possibly_left != 0) : (i += 1) {
                    if (getReadyPoll(self, i)) |ready| {
                        if (ready == old_poll) {
                            setReadyPoll(self, i, new_poll);
                            num_entries_possibly_left -= 1;
                        }
                    }
                }
            }

            fn sweepTimerCb(allocator: Allocator, cb: *InternalCallback(Poll, Self)) !void {
                return internalTimerSweep(allocator, cb.loop);
            }

            pub fn timerSet(t: *Timer, cb: *const fn (allocator: Allocator, t: *Timer) anyerror!void, ms: isize, repeat_ms: isize) !void {
                const internal_cb: *InternalCallback(Poll, Self) = @ptrCast(@alignCast(t));
                internal_cb.cb = @ptrCast(cb);
                // Bug: repeat_ms must be the same as ms, or 0
                const event: std.posix.Kevent = .{
                    .ident = @intFromPtr(internal_cb),
                    .filter = std.c.EVFILT_TIMER,
                    .flags = std.c.EV_ADD | @as(u16, if (repeat_ms != 0) 0 else std.c.EV_ONESHOT),
                    .fflags = 0,
                    .data = ms,
                    .udata = @intFromPtr(internal_cb),
                };
                _ = try std.posix.kevent(internal_cb.loop.fd, &.{event}, &.{}, null);
            }

            pub fn loopIntegrate(loop: *Self) !void {
                return timerSet(
                    loop.data.sweep_timer.?,
                    @ptrCast(&sweepTimerCb),
                    TIMEOUT_GRANULARITY * 1000,
                    TIMEOUT_GRANULARITY * 1000,
                );
            }

            pub fn run(self: *Self, allocator: Allocator) !void {
                try loopIntegrate(self);

                while (self.num_polls != 0) {
                    // emit pre-callback
                    try internalLoopPre(allocator, self);

                    // fetch ready polls
                    // TODO: finish implementation
                    self.num_ready_polls = try std.posix.kevent(self.fd, &.{}, self.ready_polls[0..1024], null);
                    self.current_ready_poll = 0;
                    while (self.current_ready_poll < self.num_ready_polls) : (self.current_ready_poll += 1) {
                        const maybe_poll: ?*Poll = getReadyPoll(self, self.current_ready_poll);
                        if (maybe_poll) |poll| {
                            var events: u32 = SOCKET_READABLE;
                            if (self.ready_polls[self.current_ready_poll].filter == std.c.EVFILT_WRITE) {
                                events = SOCKET_WRITABLE;
                            }
                            const err: u32 = self.ready_polls[self.current_ready_poll].flags & (std.c.EV_ERROR | std.c.EV_EOF);
                            events &= poll.events();
                            if (events != 0 or err != 0) {
                                std.debug.print("events: {d}, err: {d}\n", .{ events, err });
                                try internalDispatchReadyPoll(allocator, InternalCallback(Poll, Self), Socket, poll, err, events);
                            }
                        }
                    }
                    try internalLoopPost(allocator, self);
                }
            }

            pub fn asyncWakeup(self: *Self) !void {
                const internal_cb: *InternalCallback(Poll, Self) = @ptrCast(@alignCast(self.data.wakeup_async));
                // add a triggered oneshot event
                const kevent: std.posix.Kevent = .{
                    .ident = @intFromPtr(internal_cb),
                    .filter = std.c.EVFILT_USER,
                    .flags = std.c.EV_ADD | std.c.EV_ONESHOT,
                    .fflags = std.c.NOTE_TRIGGER,
                    .data = 0,
                    .udata = @intFromPtr(internal_cb),
                };
                _ = try std.posix.kevent(internal_cb.loop.fd, &.{kevent}, &.{}, null);
            }
        },
    }
}

pub fn PollT(comptime PollExt: type, comptime LoopType: type) type {
    return switch (build_opts.event_loop_lib) {
        .epoll => struct {
            const Self = @This();
            pub const LoopT = LoopType;

            state: packed struct {
                fd: i28,
                poll_type: PollType,
            } align(EXT_ALIGNMENT),
            ext: ?PollExt = null,

            pub fn init(allocator: Allocator, loop: *LoopT, fallthrough: bool, fd_: SocketDescriptor, poll_type: PollType) !*Self {
                if (!fallthrough) loop.num_polls += 1;
                const self = try allocator.create(Self);
                self.* = .{ .state = .{
                    .fd = @intCast(fd_),
                    .poll_type = poll_type,
                } };
                return self;
            }

            pub fn deinit(self: *Self, allocator: Allocator, loop: *LoopT) void {
                loop.num_polls -= 1;
                allocator.destroy(self);
            }

            pub fn pollType(self: *Self) PollType {
                return @enumFromInt(@intFromEnum(self.state.poll_type) & 3);
            }

            pub fn start(self: *Self, loop: *LoopT, events_: u32) !void {
                self.state.poll_type = @enumFromInt(@intFromEnum(self.pollType()) | (if ((events_ & SOCKET_READABLE) != 0) @intFromEnum(PollType.polling_in) else 0) | (if ((events_ & SOCKET_WRITABLE) != 0) @intFromEnum(PollType.polling_out) else 0));
                var event: std.os.epoll_event = undefined;
                event.events = events_;
                event.data.ptr = @intFromPtr(self);
                try std.posix.epoll_ctl(loop.fd, std.os.EPOLL.CTL_ADD, self.state.fd, &event);
            }

            pub fn stop(self: *Self, loop: *LoopT) !void {
                const old_events = self.events();
                const new_events: u32 = 0;
                var event: std.os.epoll_event = undefined;
                try std.posix.epoll_ctl(loop.fd, std.os.EPOLL.CTL_DEL, self.state.fd, &event);
                loop.updatePendingReadyPolls(self, null, old_events, new_events);
            }

            pub fn fd(self: *Self) SocketDescriptor {
                return self.state.fd;
            }

            pub fn events(self: *Self) u32 {
                return ((if ((@intFromEnum(self.state.poll_type) & @intFromEnum(PollType.polling_in)) != 0) @as(u32, SOCKET_READABLE) else 0) | (if ((@intFromEnum(self.state.poll_type) & @intFromEnum(PollType.polling_out)) != 0) @as(u32, SOCKET_WRITABLE) else 0));
            }

            pub fn change(self: *Self, loop: *LoopT, events_: u32) !void {
                const old_events = self.events();
                if (old_events != events_) {
                    self.state.poll_type = @enumFromInt(@intFromEnum(self.pollType()) | (if ((events_ & SOCKET_READABLE) != 0) @intFromEnum(PollType.polling_in) else 0) | (if ((events_ & SOCKET_WRITABLE) != 0) @intFromEnum(PollType.polling_out) else 0));
                    var event: std.os.epoll_event = undefined;
                    event.events = events_;
                    event.data.ptr = @intFromPtr(self);
                    try std.posix.epoll_ctl(loop.fd, std.os.EPOLL.CTL_MOD, self.state.fd, &event);
                    // possibly need to set removed polls to null in pending ready poll list
                    // internalLoopUpdatePendingReadyPolls(loop, self, self, old_events, events)
                }
            }

            pub fn setPollType(self: *Self, poll_type: PollType) void {
                self.state.poll_type = @enumFromInt(@intFromEnum(poll_type) | (@intFromEnum(self.state.poll_type) & 12));
            }
        },
        else => struct {
            const Self = @This();
            pub const LoopT = LoopType;

            state: packed struct {
                fd: i28,
                poll_type: PollType,
            } align(EXT_ALIGNMENT),
            ext: ?PollExt = null,

            pub fn init(allocator: Allocator, loop: *LoopT, fallthrough: bool, fd_: SocketDescriptor, poll_type: PollType) !*Self {
                if (!fallthrough) loop.num_polls += 1;
                const self = try allocator.create(Self);
                self.* = .{
                    .state = .{
                        .fd = @intCast(fd_),
                        .poll_type = poll_type,
                    },
                };
                return self;
            }

            pub fn deinit(self: *Self, allocator: Allocator, loop: *LoopT) void {
                loop.num_polls -= 1;
                allocator.destroy(self);
            }

            pub fn pollType(self: *Self) PollType {
                return @enumFromInt(@intFromEnum(self.state.poll_type) & 3);
            }

            pub fn start(self: *Self, loop: *LoopT, events_: u32) !void {
                self.state.poll_type = @enumFromInt(@intFromEnum(self.pollType()) | (if ((events_ & SOCKET_READABLE) != 0) @intFromEnum(PollType.polling_in) else 0) | (if ((events_ & SOCKET_WRITABLE) != 0) @intFromEnum(PollType.polling_out) else 0));
                _ = try kqueueChange(loop.fd, self.state.fd, 0, events_, self);
            }

            fn kqueueChange(kqfd: std.posix.fd_t, fd_: std.posix.fd_t, old_events: u32, new_events: u32, user_data: ?*anyopaque) !usize {
                var change_list: [2]std.posix.Kevent = undefined;
                var len: u8 = 0;
                // Do they differ in readable?
                if ((new_events & SOCKET_READABLE) != (old_events & SOCKET_READABLE)) {
                    change_list[len] = .{
                        .ident = @intCast(fd_),
                        .filter = std.c.EVFILT_READ,
                        .flags = if ((new_events & SOCKET_READABLE) != 0) std.c.EV_ADD else std.c.EV_DELETE,
                        .fflags = 0,
                        .data = 0,
                        .udata = @intFromPtr(user_data),
                    };
                    len += 1;
                }

                // Do they differ in writable?
                if ((new_events & SOCKET_WRITABLE) != (old_events & SOCKET_WRITABLE)) {
                    change_list[len] = .{
                        .ident = @intCast(fd_),
                        .filter = std.c.EVFILT_WRITE,
                        .flags = if ((new_events & SOCKET_WRITABLE) != 0) std.c.EV_ADD else std.c.EV_DELETE,
                        .fflags = 0,
                        .data = 0,
                        .udata = @intFromPtr(user_data),
                    };
                    len += 1;
                }

                return @intCast(std.c.kevent(kqfd, change_list[0..len].ptr, len, change_list[0..0].ptr, 0, null));
            }

            pub fn stop(self: *Self, loop: *LoopT) !void {
                const old_events = self.events();
                const new_events: u32 = 0;
                if (old_events != 0) _ = try kqueueChange(loop.fd, self.state.fd, old_events, new_events, null);
                loop.updatePendingReadyPolls(self, null, old_events, new_events);
            }

            pub fn fd(self: *Self) SocketDescriptor {
                return self.state.fd;
            }

            pub fn events(self: *Self) u32 {
                return ((if ((@intFromEnum(self.state.poll_type) & @intFromEnum(PollType.polling_in)) != 0) @as(u32, SOCKET_READABLE) else 0) | (if ((@intFromEnum(self.state.poll_type) & @intFromEnum(PollType.polling_out)) != 0) @as(u32, SOCKET_WRITABLE) else 0));
            }

            pub fn change(self: *Self, loop: *LoopT, events_: u32) !void {
                const old_events = self.events();
                if (old_events != events_) {
                    self.state.poll_type = @enumFromInt(@intFromEnum(self.pollType()) | (if ((events_ & SOCKET_READABLE) != 0) @intFromEnum(PollType.polling_in) else 0) | (if ((events_ & SOCKET_WRITABLE) != 0) @intFromEnum(PollType.polling_out) else 0));
                    _ = try kqueueChange(loop.fd, self.state.fd, old_events, events_, self);
                    // possibly need to set removed polls to null in pending ready poll list
                    // internalLoopUpdatePendingReadyPolls(loop, self, self, old_events, events)
                }
            }

            pub fn setPollType(self: *Self, poll_type: PollType) void {
                self.state.poll_type = @enumFromInt(@intFromEnum(poll_type) | (@intFromEnum(self.state.poll_type) & 12));
            }

            pub fn resize(self: *Self, allocator: Allocator, loop: *LoopT, comptime T: type) !*T {
                if (T == Self) return self;
                const events_ = self.events();
                var new_self: *T = @ptrCast(@alignCast(self));
                if (!allocator.resize(std.mem.asBytes(self), @sizeOf(T))) {
                    new_self = try allocator.create(T);
                    if (@sizeOf(Self) == @sizeOf(T)) {
                        @memcpy(std.mem.asBytes(new_self), std.mem.asBytes(self));
                    } else if (@sizeOf(Self) < @sizeOf(T)) {
                        @memcpy(std.mem.asBytes(new_self)[0..@sizeOf(Self)], std.mem.asBytes(self));
                    } else {
                        @memcpy(std.mem.asBytes(new_self), std.mem.asBytes(self)[0..@sizeOf(T)]);
                    }
                }
                if (@intFromPtr(self) != @intFromPtr(new_self) and events_ != 0) {
                    defer allocator.destroy(self);
                    // unable to resize existing allocation, copied to new allocation
                    _ = try kqueueChange(loop.fd, new_self.state.fd, 0, events_, @ptrCast(@alignCast(new_self)));
                    loop.updatePendingReadyPolls(self, @ptrCast(@alignCast(new_self)), events_, events_);
                }
                return new_self;
            }
        },
    };
}
