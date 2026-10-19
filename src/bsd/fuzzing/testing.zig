const builtin = @import("builtin");
const epoll = @import("epoll.zig");
const std = @import("std");

pub const isEpollFuzzing = epoll.isEpollFuzzing;
pub const numFds = epoll.numFds;
pub const setConsumableData = epoll.setConsumableData;
pub const setTeardown = epoll.setTeardown;
