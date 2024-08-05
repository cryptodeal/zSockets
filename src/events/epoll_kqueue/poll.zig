const build_opts = @import("build_opts");
const std = @import("std");
const utils = @import("utils.zig");
const zs = @import("../../zsockets.zig");

const Allocator = std.mem.Allocator;

pub const Poll = switch (build_opts.event_loop_lib) {
    // .epoll => Epoll,
    .kqueue => Kqueue,
    else => @compileError(std.fmt.comptimePrint("Unsupported event loop library: {s}", .{@tagName(build_opts.event_loop_lib)})),
};

pub const Kqueue = packed struct {
    state: packed struct {
        fd: i28,
        poll_type: zs.PollType,
    },

    pub fn init(loop: *zs.Loop, fallthrough: bool, fd_: zs.SocketDescriptor, poll_type: zs.PollType) Kqueue {
        if (!fallthrough) loop.num_polls += 1;
        return .{
            .state = .{
                .fd = @intCast(fd_),
                .poll_type = poll_type,
            },
        };
    }

    pub fn deinit(_: *Kqueue, loop: *zs.Loop) void {
        loop.num_polls -= 1;
    }

    pub fn events(self: *const Kqueue) u32 {
        const poll_type = @intFromEnum(self.state.poll_type);
        const polling_in = @intFromEnum(zs.PollType.polling_in);
        const polling_out = @intFromEnum(zs.PollType.polling_out);
        return ((if ((poll_type & polling_in) != 0) @as(u32, zs.SOCKET_READABLE) else 0) |
            (if ((poll_type & polling_out) != 0) @as(u32, zs.SOCKET_WRITABLE) else 0));
    }

    pub fn fd(self: *const Kqueue) zs.SocketDescriptor {
        return self.state.fd;
    }

    pub fn @"type"(self: *const Kqueue) zs.PollType {
        return @enumFromInt(@intFromEnum(self.state.poll_type) & 3);
    }

    pub fn setType(self: *Kqueue, poll_type: zs.PollType) void {
        self.state.poll_type = @enumFromInt(@intFromEnum(poll_type) | (@intFromEnum(self.state.poll_type) & 12));
    }

    pub fn acceptPollEvent(_: *Kqueue) usize {
        return 0;
    }

    pub fn start(self: *Kqueue, loop: *zs.Loop, evnts: u32) !void {
        const polling_in = @intFromEnum(zs.PollType.polling_in);
        const polling_out = @intFromEnum(zs.PollType.polling_out);
        self.state.poll_type = @enumFromInt(@intFromEnum(self.type()) | (if ((evnts & zs.SOCKET_READABLE) != 0) polling_in else 0) | (if ((evnts & zs.SOCKET_WRITABLE) != 0) polling_out else 0));
        _ = try utils.kqueueChange(loop.fd, self.state.fd, 0, evnts, self);
    }

    pub fn stop(self: *Kqueue, loop: *zs.Loop) !void {
        const old_events = self.events();
        const new_events: u32 = 0;
        if (old_events != 0) _ = try utils.kqueueChange(loop.fd, self.state.fd, old_events, new_events, null);
        loop.updatePendingReadyPolls(self, null, old_events, new_events);
    }

    pub fn change(self: *Kqueue, loop: *zs.Loop, evnts: u32) !void {
        const old_events = self.events();
        if (old_events != evnts) {
            const polling_in = @intFromEnum(zs.PollType.polling_in);
            const polling_out = @intFromEnum(zs.PollType.polling_out);
            self.state.poll_type = @enumFromInt(@intFromEnum(self.type()) | (if ((evnts & zs.SOCKET_READABLE) != 0) polling_in else 0) | (if ((evnts & zs.SOCKET_WRITABLE) != 0) polling_out else 0));
            _ = try utils.kqueueChange(loop.fd, self.state.fd, old_events, evnts, self);
            // possibly need to set removed polls to null in pending ready poll list
            // internalLoopUpdatePendingReadyPolls(loop, self, self, old_events, events)
        }
    }

    pub fn resizeUpdate(self: *Kqueue, loop: *zs.Loop) !void {
        const evnts = self.events();
        // if (evnts != 0) {
        _ = try utils.kqueueChange(loop.fd, self.state.fd, 0, evnts, self);
        loop.updatePendingReadyPolls(self, self, evnts, evnts);
        // }
    }
};
