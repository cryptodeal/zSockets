const EXT_ALIGNMENT = @import("../../constants.zig").EXT_ALIGNMENT;
const InternalLoopData = @import("../loop_data.zig").InternalLoopData;

pub const Poll = struct {
    data: InternalLoopData align(EXT_ALIGNMENT),
    // TODO(cryptodeal): need to add GCD as dependency/link
};
