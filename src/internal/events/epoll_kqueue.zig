const build_opts = @import("build_opts");
const builtin = @import("builtin");
const socket = @import("../../socket.zig");
const std = @import("std");

const EXT_ALIGNMENT = @import("../../zsockets.zig").EXT_ALIGNMENT;
const InternalLoopData = @import("../loop_data.zig").InternalLoopData;

const SocketDescriptor = socket.SocketDescriptor;
const StructField = std.builtin.Type.StructField;

pub const SOCKET_READABLE = 1;
pub const SOCKET_WRITABLE = 2;

pub const NativePoll = if (build_opts.USE_EPOLL) std.os.linux.epoll_event else std.posix.Kevent;

pub const Loop = struct {
    data: InternalLoopData align(EXT_ALIGNMENT),
    num_polls: u64,
    num_ready_polls: u64,
    current_ready_poll: u64,
    fd: c_int,
    ready_polls: [1024]NativePoll,
};

pub const Poll = struct {
    state: packed struct {
        fd: i28,
        poll_type: u4,
    } align(EXT_ALIGNMENT),

    pub fn pollFd(self: *Poll) SocketDescriptor {
        return self.state.fd;
    }
};
