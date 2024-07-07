/// Specifies the type of poll (and what is polled for).
pub const PollType = enum(u4) {
    // 2 first bits
    socket = 0,
    socket_shutdown = 1,
    semi_socket = 2,
    callback = 3,

    // Two last bits
    polling_out = 4,
    polling_in = 8,
};

pub const Socket = struct {};
