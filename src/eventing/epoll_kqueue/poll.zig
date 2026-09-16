const build_opts = @import("build_opts");
const constants = @import("constants.zig");
const std = @import("std");
const utils = @import("utils.zig");

const Extension = @import("../../extension.zig");

const Loop = @import("loop.zig");
const PollType = @import("../../internal/internal.zig").PollType;

const Self = @This();

state: struct {
    fd: std.posix.fd_t = undefined,
    poll_type: PollType = .polling_out,
} = .{},
ext: Extension = .{},

pub fn create(self: *Self, allocator: std.mem.Allocator, _: std.Io, loop: *Loop, fallthrough: bool, comptime ExtT: ?type) !void {
    if (!fallthrough) loop.polls_count += 1;
    self.ext = try Extension.init(allocator, ExtT);
}

pub fn init(self: *Self, fd_: std.posix.fd_t, poll_type: PollType) void {
    self.state.fd = fd_;
    self.state.poll_type = poll_type;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator, loop: *Loop) void {
    loop.polls_count -= 1;
    self.ext.deinit(allocator);
}

pub fn resize(self: *Self, loop: *Loop) void {
    const events_ = self.events();
    if (events_ != 0) {
        if (build_opts.event_backend == .epoll) {
            self.state.poll_type = self.pollType();
            self.change(loop, events_);
        } else {
            _ = utils.kqueueChange(loop.fd, self.state.fd, 0, events_, self);
        }
        loop.updatePendingReadyPolls(self, self, events_, events_);
    }
}

pub fn getExt(self: *Self, comptime T: type) ?*T {
    return @ptrCast(@alignCast(self.ext.ptr));
}

pub fn setType(self: *Self, poll_type: PollType) void {
    self.state.poll_type = @enumFromInt(@intFromEnum(poll_type) | (@intFromEnum(self.state.poll_type) & 12));
}

pub fn pollType(self: *const Self) PollType {
    return @enumFromInt(@intFromEnum(self.state.poll_type) & 3);
}

pub fn start(self: *Self, loop: *Loop, events_: u32) void {
    self.state.poll_type = @enumFromInt(@intFromEnum(self.pollType()) | (if (events_ & constants.socket_readable != 0) @intFromEnum(PollType.polling_in) else 0) | (if (events_ & constants.socket_writable != 0) @intFromEnum(PollType.polling_out) else 0));
    if (build_opts.event_backend == .epoll) {
        var event: std.os.linux.epoll_event = .{
            .events = events_,
            .data = .{ .ptr = @intFromPtr(self) },
        };
        _ = std.os.linux.epoll_ctl(loop.fd, std.os.linux.EPOLL.CTL_ADD, self.state.fd, &event);
    } else {
        _ = utils.kqueueChange(loop.fd, self.state.fd, 0, events_, self);
    }
}

pub fn events(self: *const Self) u32 {
    return (if (@intFromEnum(self.state.poll_type) & @intFromEnum(PollType.polling_in) != 0) @as(u32, constants.socket_readable) else 0) | (if (@intFromEnum(self.state.poll_type) & @intFromEnum(PollType.polling_out) != 0) @as(u32, constants.socket_writable) else 0);
}

pub fn change(self: *Self, loop: *Loop, events_: u32) void {
    const old_events = self.events();
    if (old_events != events_) {
        self.state.poll_type = @enumFromInt(@intFromEnum(self.pollType()) | (if (events_ & constants.socket_readable != 0) @intFromEnum(PollType.polling_in) else 0) | (if (events_ & constants.socket_writable != 0) @intFromEnum(PollType.polling_out) else 0));
        if (build_opts.event_backend == .epoll) {
            var event: std.os.linux.epoll_event = .{
                .events = events_,
                .data = .{ .ptr = @intFromPtr(self) },
            };
            _ = std.os.linux.epoll_ctl(loop.fd, std.os.linux.EPOLL.CTL_MOD, self.state.fd, &event);
        } else {
            _ = utils.kqueueChange(loop.fd, self.state.fd, old_events, events_, self);
        }
    }
}

pub fn stop(self: *Self, loop: *Loop) void {
    const old_events = self.events();
    const new_events: u32 = 0;
    if (build_opts.event_backend == .epoll) {
        var event: std.os.linux.epoll_event = undefined;
        _ = std.os.linux.epoll_ctl(loop.fd, std.os.linux.EPOLL.CTL_DEL, self.state.fd, &event);
    }
    // kqueue automatically removes the fd from the set on close, so we
    // can avoid expensive system call here
    // else {
    //     if (old_events != 0) {
    //         _ = utils.kqueueChange(loop.fd, self.state.fd, old_events, new_events, null);
    //     }
    // }
    loop.updatePendingReadyPolls(self, null, old_events, new_events);
}

pub fn fd(self: *Self) std.posix.fd_t {
    return self.state.fd;
}

pub fn acceptEvent(self: *Self) usize {
    if (build_opts.event_backend == .epoll) {
        var buf: u64 = undefined;
        _ = std.os.linux.read(self.fd(), std.mem.asBytes(&buf).ptr, @sizeOf(u64));
        return buf;
    } else {
        return 0;
    }
}
