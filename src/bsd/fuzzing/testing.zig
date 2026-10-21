const builtin = @import("builtin");
const fuzz = @import("fuzz.zig");
const std = @import("std");

pub const isEpollFuzzing = fuzz.isEpollFuzzing;
pub const numFds = fuzz.numFds;
pub const setConsumableData = fuzz.setConsumableData;
pub const setTeardown = fuzz.setTeardown;
