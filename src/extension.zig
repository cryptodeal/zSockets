const std = @import("std");

const Self = @This();

ptr: ?*anyopaque = null,
create_cb: *const fn (std.mem.Allocator) anyerror!*anyopaque,
destroy_cb: *const fn (std.mem.Allocator, *anyopaque) void,
clone_cb: *const fn (*anyopaque, *anyopaque) void,
as_bytes_cb: *const fn (*anyopaque) []u8,
copy_to_cb: *const fn (*anyopaque, []u8) void,
print_cb: *const fn () void,
get_async_socket_data: *const fn (*anyopaque) ?*anyopaque,

pub fn init(allocator: std.mem.Allocator, comptime T: type) !Self {
    return .{
        .ptr = @ptrCast(@alignCast(try allocator.create(T))),
        .print_cb = (struct {
            pub fn call() void {
                std.debug.print("Extension Type: {s}\n", .{@typeName(T)});
            }
        }).call,
        .create_cb = (struct {
            pub fn call(a: std.mem.Allocator) !*anyopaque {
                const res = try a.create(T);
                return @ptrCast(@alignCast(res));
            }
        }).call,
        .destroy_cb = (struct {
            pub fn call(a: std.mem.Allocator, value: *anyopaque) void {
                a.destroy(@as(*T, @ptrCast(@alignCast(value))));
            }
        }).call,
        .clone_cb = (struct {
            pub fn call(orig: *anyopaque, dest: *anyopaque) void {
                @memcpy(std.mem.asBytes(@as(*T, @ptrCast(@alignCast(dest)))), std.mem.asBytes(@as(*T, @ptrCast(@alignCast(orig)))));
            }
        }).call,
        .as_bytes_cb = (struct {
            pub fn call(value: *anyopaque) []u8 {
                return std.mem.asBytes(@as(*T, @ptrCast(@alignCast(value))));
            }
        }).call,
        .copy_to_cb = (struct {
            pub fn call(value: *anyopaque, buf: []u8) void {
                const len = @min(buf.len, @sizeOf(T));
                @memcpy(buf[0..len], std.mem.asBytes(@as(*T, @ptrCast(@alignCast(value))))[0..len]);
            }
        }).call,
        .get_async_socket_data = (struct {
            pub fn call(value: *anyopaque) ?*anyopaque {
                if (@typeInfo(T) == .pointer) return null;
                if (@hasField(T, "async_socket_data")) {
                    return &@field(@as(*T, @ptrCast(@alignCast(value))), "async_socket_data");
                } else {
                    return null;
                }
            }
        }).call,
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    if (self.ptr) |ptr| {
        self.destroy_cb(allocator, ptr);
        self.ptr = null;
    }
}

pub fn print(self: Self) void {
    self.print_cb();
}

pub fn dupe(self: Self, allocator: std.mem.Allocator) !Self {
    if (self.ptr) |p| {
        const new_ptr = try self.create_cb(allocator);
        self.clone_cb(p, new_ptr);
        return .{
            .ptr = new_ptr,
            .print_cb = self.print_cb,
            .create_cb = self.create_cb,
            .destroy_cb = self.destroy_cb,
            .clone_cb = self.clone_cb,
            .as_bytes_cb = self.as_bytes_cb,
            .copy_to_cb = self.copy_to_cb,
            .get_async_socket_data = self.get_async_socket_data,
        };
    } else return error.NullExtension;
}

pub fn get(self: Self, comptime T: type) ?*T {
    return @ptrCast(@alignCast(self.ptr));
}

pub fn getAsyncSocketData(self: Self, comptime T: type) ?*T {
    return @ptrCast(@alignCast(self.get_async_socket_data(self.ptr.?)));
}
