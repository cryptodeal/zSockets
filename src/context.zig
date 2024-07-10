const std = @import("std");
const internal = @import("internal/internal.zig");

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
