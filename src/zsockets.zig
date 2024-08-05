const bsd = @import("bsd.zig");
const socket = @import("socket.zig");
const std = @import("std");

pub usingnamespace @import("events.zig");
pub usingnamespace @import("internal.zig");

pub const Context = @import("context.zig").Context;
pub const ListenSocket = socket.ListenSocket;
pub const Socket = socket.Socket;

pub const c = struct {
    pub fn rand() usize {
        return @intCast(bsd.c.rand());
    }

    pub fn srand(seed: u32) void {
        bsd.c.srand(seed);
    }
};

test {
    std.testing.refAllDecls(@import("crypto/sni_tree.zig"));
}
