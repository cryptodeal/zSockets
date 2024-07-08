const build_opts = @import("build_opts");
const builtin = @import("builtin");

pub const SOCKET_READABLE = 1;
pub const SOCKET_WRITABLE = 2;

// TODO(cryptodeal): implement epoll/kqueue types
// pub const Loop = switch (build_opts.USE_EPOLL) {
//     true => struct {
//         data: InternalLoopData align(EXT_ALIGNMENT),
//         num_polls: usize,
//         num_ready_polls: usize,
//         fd: c_int,
//         ready_polls: [1024]epoll_event,
//     },
//     else => struct {},
// };

pub const Poll = struct {
    boost_block: ?*anyopaque,
    // TODO(cryptodeal): `fd` should be `SOCKET` if windows target
    fd: c_int,
    poll_type: u8,
    events: c_int,
};
