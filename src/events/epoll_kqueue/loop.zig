const build_opts = @import("build_opts");
const std = @import("std");
const utils = @import("utils.zig");
const zs = @import("../../zsockets.zig");

const Callback = @import("../../internal/callback.zig");
const LoopData = @import("../../internal/loop_data.zig");

const Allocator = std.mem.Allocator;
const Kevent = std.c.Kevent;

pub const Loop = switch (build_opts.event_loop_lib) {
    // .epoll => Epoll,
    .kqueue => Kqueue,
    inline else => |tag| @compileError(std.fmt.comptimePrint("Unsupported event loop library: {s}", .{@tagName(tag)})),
};

const Kqueue = struct {
    data: LoopData,
    num_polls: u64 = 0,
    num_ready_polls: u64 = 0,
    current_ready_poll: u64 = 0,
    fd: i32,
    ready_polls: [1024]Kevent = undefined,
    _ext: zs.Extension = .{},

    pub fn init(
        allocator: Allocator,
        comptime Extension: ?type,
        _: ?*anyopaque, // hint (unused)
        wakeup_cb: *const fn (allocator: Allocator, loop: *Kqueue) anyerror!void,
        pre_cb: *const fn (allocator: Allocator, loop: *Kqueue) anyerror!void,
        post_cb: *const fn (allocator: Allocator, loop: *Kqueue) anyerror!void,
    ) !*Kqueue {
        const loop = try allocator.create(Kqueue);
        errdefer allocator.destroy(loop);
        if (Extension) |T| loop._ext = try zs.Extension.init(allocator, T);
        loop.fd = std.c.kqueue();
        try utils.initLoopData(allocator, loop, wakeup_cb, pre_cb, post_cb);
        return loop;
    }

    pub fn deinit(self: *Kqueue, allocator: Allocator) void {
        self._ext.deinit(allocator);
        // TODO(cryptodeal): finish implementation
    }

    pub fn run(self: *Kqueue, allocator: Allocator) !void {
        try utils.loopIntegrate(self);

        while (self.num_polls != 0) {
            // emit pre-callback
            try utils.internalLoopPre(allocator, self);

            self.num_ready_polls = @intCast(std.c.kevent(self.fd, &[_]Kevent{}, 0, &self.ready_polls, self.ready_polls.len, null));
            self.current_ready_poll = 0;
            while (self.current_ready_poll < self.num_ready_polls) : (self.current_ready_poll += 1) {
                const poll = self.getReadyPoll(self.current_ready_poll);
                if (poll) |p| {
                    var events: u32 = zs.SOCKET_READABLE;
                    if (self.ready_polls[self.current_ready_poll].filter == std.c.EVFILT_WRITE) {
                        events = zs.SOCKET_WRITABLE;
                    }
                    const err: u32 = self.ready_polls[self.current_ready_poll].flags & (std.c.EV_ERROR | std.c.EV_EOF);
                    events &= p.events();
                    std.debug.print("events: {d}, err: {d}\n", .{ events, err });
                    if (events != 0 or err != 0) {
                        try utils.internalDispatchReadyPoll(allocator, p, err, events);
                    }
                }
            }
            try utils.internalLoopPost(allocator, self);
        }
    }

    // internal functions

    pub fn updatePendingReadyPolls(self: *Kqueue, old_poll: *zs.Poll, new_poll: ?*zs.Poll, _: u32, _: u32) void {
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

    inline fn getReadyPoll(self: *Kqueue, index: anytype) ?*zs.Poll {
        return @ptrFromInt(self.ready_polls[index].udata);
    }

    inline fn setReadyPoll(self: *Kqueue, index: anytype, poll: ?*zs.Poll) void {
        self.ready_polls[index].udata = @intFromPtr(poll);
    }

    pub fn createTimer(self: *Kqueue, allocator: Allocator, fallthrough: bool, comptime Extension: ?type) !*zs.Timer {
        const cb = try Callback.init(allocator, Extension);
        cb.loop = self;
        cb.expects_loop = true;
        cb.leave_poll_ready = false;
        // `Poll.setType` only changes the type, does not set initial value.
        cb.p.state.poll_type = .polling_in;
        cb.p.setType(.callback);
        if (!fallthrough) self.num_polls += 1;
        return @ptrCast(@alignCast(cb));
    }

    fn asyncWakeup(
        a: *zs.InternalAsync,
    ) void {
        const internal_cb: *Callback = @ptrCast(@alignCast(a));
        const event: std.c.Kevent = .{
            .ident = @intFromPtr(internal_cb),
            .filter = std.c.EVFILT_USER,
            .flags = std.c.EV_ADD | std.c.EV_ONESHOT,
            .fflags = std.c.NOTE_TRIGGER,
            .data = 0,
            .udata = @intFromPtr(internal_cb),
        };
        _ = std.c.kevent(internal_cb.loop.fd, &[_]Kevent{event}, 1, &[_]Kevent{}, 0, null);
    }

    pub fn wakeup(self: *Kqueue) void {
        asyncWakeup(self.data.wakeup_async);
    }

    pub fn timerSet(t: *zs.Timer, cb: *const fn (allocator: Allocator, t: *zs.Timer) anyerror!void, ms: isize, repeat_ms: isize) !void {
        const internal_cb: *Callback = @ptrCast(@alignCast(t));
        internal_cb.cb = @ptrCast(@alignCast(cb));
        // Bug: `repeat_ms` must be the same as `ms` or `0`
        const event: std.c.Kevent = .{
            .ident = @intFromPtr(internal_cb),
            .filter = std.c.EVFILT_TIMER,
            .flags = std.c.EV_ADD | @as(u16, if (repeat_ms != 0) 0 else std.c.EV_ONESHOT),
            .fflags = 0,
            .data = ms,
            .udata = @intFromPtr(internal_cb),
        };
        _ = std.c.kevent(internal_cb.loop.fd, &[_]Kevent{event}, 1, &[_]Kevent{}, 0, null);
    }

    pub fn createAsync(self: *Kqueue, allocator: Allocator, fallthrough: bool, comptime Extension: ?type) !*zs.InternalAsync {
        const cb = try Callback.init(allocator, Extension);
        cb.loop = self;
        cb.expects_loop = true;
        cb.leave_poll_ready = false;
        // `Poll.setType` only changes the type, does not set initial value.
        cb.p.state.poll_type = .polling_in;
        cb.p.setType(.callback);
        if (!fallthrough) self.num_polls += 1;
        return cb;
    }

    pub fn asyncSet(a: *zs.InternalAsync, cb: *const fn (allocator: Allocator, a: *zs.InternalAsync) anyerror!void) void {
        const internal_cb: *Callback = @ptrCast(@alignCast(a));
        internal_cb.cb = @ptrCast(@alignCast(cb));
    }
};
