const std = @import("std");

pub fn ExtensionEnum(comptime extensions: []const type) type {
    const has_void = if (std.mem.indexOf(type, extensions, void)) |_| true else false;
    var enum_decls: [extensions.len + 1]std.builtin.Type.EnumField = undefined;
    if (has_void) |_| {
        inline for (extensions, 0..) |ext, i| {
            enum_decls[i] = .{ .name = @typeName(ext), .value = i };
        }
    } else {
        enum_decls[0] = .{ .name = "void", .value = 0 };
        inline for (extensions, 1..) |ext, i| {
            enum_decls[i] = .{ .name = @typeName(ext), .value = i };
        }
    }
    return @Type(.{
        .Enum = .{
            .tag_type = std.math.IntFittingRange(0, if (has_void) extensions.len - 1 else extensions.len),
            .fields = &enum_decls,
            .decls = &.{},
            .is_exhaustive = true,
        },
    });
}

pub fn PollUnion(comptime extensions: []const type) type {
    const ExtEnum = ExtensionEnum(extensions);
    return union(ExtEnum) {};
}
