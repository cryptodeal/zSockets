const std = @import("std");

const Self = @This();

ptr: ?*anyopaque = null,
create_cb: ?*const fn (std.mem.Allocator) anyerror!*anyopaque = null,
destroy_cb: ?*const fn (std.mem.Allocator, *anyopaque) void = null,
clone_cb: ?*const fn (*anyopaque, *anyopaque) void = null,
as_bytes_cb: ?*const fn (*anyopaque) []u8 = null,
copy_to_cb: ?*const fn (*anyopaque, []u8) void = null,

pub fn init(allocator: std.mem.Allocator, comptime MaybeT: ?type) !Self {
    var self: Self = .{};
    if (MaybeT) |T| {
        self.ptr = @ptrCast(@alignCast(try allocator.create(T)));
        self.create_cb = (struct {
            const CallbackT = T;
            pub fn call(a: std.mem.Allocator) !*anyopaque {
                const res = try a.create(CallbackT);
                return @ptrCast(@alignCast(res));
            }
        }).call;
        self.destroy_cb = (struct {
            const CallbackT = T;
            pub fn call(a: std.mem.Allocator, value: *anyopaque) void {
                a.destroy(@as(*CallbackT, @ptrCast(@alignCast(value))));
            }
        }).call;
        self.clone_cb = (struct {
            const CallbackT = T;
            pub fn call(orig: *anyopaque, dest: *anyopaque) void {
                @memcpy(std.mem.asBytes(@as(*CallbackT, @ptrCast(@alignCast(dest)))), std.mem.asBytes(@as(*CallbackT, @ptrCast(@alignCast(orig)))));
            }
        }).call;
        self.as_bytes_cb = (struct {
            const CallbackT = T;
            pub fn call(value: *anyopaque) []u8 {
                return std.mem.asBytes(@as(*CallbackT, @ptrCast(@alignCast(value))));
            }
        }).call;
        self.copy_to_cb = (struct {
            const CallbackT = T;
            pub fn call(value: *anyopaque, buf: []u8) void {
                const len = @min(buf.len, @sizeOf(CallbackT));
                @memcpy(buf[0..len], std.mem.asBytes(@as(*CallbackT, @ptrCast(@alignCast(value))))[0..len]);
            }
        }).call;
    }
    return self;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    if (self.ptr) |ptr| {
        self.destroy_cb.?(allocator, ptr);
        inline for (std.meta.fields(Self)) |field| {
            @field(self, field.name) = null;
        }
    }
}

pub fn dupe(self: Self, allocator: std.mem.Allocator) !Self {
    if (self.ptr) |p| {
        const new_ptr = try self.create_cb.?(allocator);
        self.clone_cb.?(p, new_ptr);
        return .{
            .ptr = new_ptr,
            .create_cb = self.create_cb,
            .destroy_cb = self.destroy_cb,
            .clone_cb = self.clone_cb,
            .as_bytes_cb = self.as_bytes_cb,
            .copy_to_cb = self.copy_to_cb,
        };
    } else return .{};
}
