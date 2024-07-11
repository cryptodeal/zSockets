const build_opts = @import("build_opts");
const builtin = @import("builtin");

const EXT_ALIGNMENT = @import("../../constants.zig").EXT_ALIGNMENT;
const InternalLoopData = @import("../loop_data.zig").InternalLoopData;

pub const SOCKET_READABLE = 1;
pub const SOCKET_WRITABLE = 2;

pub const Loop = struct {
    data: InternalLoopData align(EXT_ALIGNMENT),
    io: ?*anyopaque,
    is_default: bool,
};

pub const Poll = struct {
    boost_block: ?*anyopaque,
    fd: if (builtin.target.os.tag == .windows) *anyopaque else c_int,
    poll_type: u8,
    events: c_int,
};
