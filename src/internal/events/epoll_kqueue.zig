const build_opts = @import("build_opts");
const builtin = @import("builtin");
const constants = @import("../../constants.zig");
const internal = @import("../internal.zig");
const socket = @import("../../socket.zig");
const std = @import("std");

const EXT_ALIGNMENT = constants.EXT_ALIGNMENT;
const RECV_BUFFER_LENGTH = constants.RECV_BUFFER_LENGTH;
const RECV_BUFFER_PADDING = constants.RECV_BUFFER_PADDING;
const InternalLoopData = @import("../loop_data.zig").InternalLoopData;

const Allocator = std.mem.Allocator;
const InternalCallback = internal.InternalCallback;
const PollType = internal.PollType;
const SocketDescriptor = socket.SocketDescriptor;
const StructField = std.builtin.Type.StructField;
const Timer = internal.Timer;

pub const SOCKET_READABLE = 1;
pub const SOCKET_WRITABLE = 2;

pub const NativePoll = if (build_opts.event_loop_lib == .epoll) std.os.linux.epoll_event else std.posix.Kevent;

pub const Loop = struct {
    data: InternalLoopData align(EXT_ALIGNMENT),
    num_polls: u64,
    num_ready_polls: u64,
    current_ready_poll: u64,
    fd: i32,
    ready_polls: [1024]NativePoll,

    // pub fn init(
    //     allocator: Allocator,
    //     hint: ?*anyopaque,
    //     wakeup_cb: *const fn (loop: *Loop) anyerror!void,
    //     pre_cb: *const fn (loop: *Loop) anyerror!void,
    //     post_cb: *const fn (loop: *Loop) anyerror!void,
    //     ext_size: u32,
    // ) !*Loop {
    //     _ = post_cb; // autofix
    //     _ = pre_cb; // autofix
    //     _ = hint; // autofix
    //     _ = wakeup_cb; // autofix
    //     var res: *Loop = @ptrCast(@alignCast(try allocator.alloc(u8, @sizeOf(Loop) + ext_size)));
    //     errdefer allocator.free(std.mem.asBytes(res));
    //     res.num_polls = 0;
    //     res.num_ready_polls = 0;
    //     res.current_ready_poll = 0;

    //     if (build_opts.event_loop_lib == .epoll) {
    //         res.fd = try std.posix.epoll_create1(std.os.linux.EPOLL.CLOEXEC);
    //     } else {
    //         res.fd = try std.posix.kqueue();
    //     }
    // }

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
};

pub const Poll = struct {
    state: packed struct {
        fd: i28,
        poll_type: PollType,
    } align(EXT_ALIGNMENT),

    pub fn pollFd(self: *Poll) SocketDescriptor {
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

    pub fn init(self: *Poll, fd: SocketDescriptor, poll_type: PollType) void {
        self.state.fd = fd;
        self.state.poll_type = poll_type;
    }
};

fn internalPollSetType(p: *Poll, poll_type: PollType) void {
    p.state.poll_type = @enumFromInt(@intFromEnum(poll_type) | (@intFromEnum(p.state.poll_type) & 12));
}
