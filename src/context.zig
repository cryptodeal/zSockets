const std = @import("std");
const internal = @import("internal/internal.zig");

const ListenSocket = internal.ListenSocket;
const LowPriorityState = internal.LowPriorityState;
const Socket = internal.Socket;
const SocketCtx = internal.SocketCtx;

// default function pointers

pub fn isLowPriorityHandler(_: *Socket) LowPriorityState {
    return .none;
}

pub fn socketCtxTimestamp(_: i32, context: *SocketCtx) u16 {
    return context.timestamp;
}

pub fn listenSocketClose(ssl: i32, ls: *ListenSocket) void {
    _ = ssl; // autofix
    _ = ls; // autofix
}
