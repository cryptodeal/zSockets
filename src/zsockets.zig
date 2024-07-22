pub usingnamespace @import("internal.zig");

pub const Extensions = struct {
    socket: type = void,
    socket_ctx: type = void,
    loop: type = void,
    poll: type = void,
    timer: type = void,
};

pub fn Network(ssl: bool, comptime extensions: Extensions) type {
    return struct {
        pub const Loop = @import("events.zig").Loop(ssl, extensions);
        pub const Poll = Loop.Poll;
        pub const Socket = Loop.Socket;
        pub const SocketCtx = Socket.Context;
        pub const ListenSocket = Socket.ListenSocket;
    };
}
