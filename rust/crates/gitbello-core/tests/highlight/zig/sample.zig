//! A small allocator demo.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// The largest buffer.
pub const max_len: usize = 0x1000;

// A packed flag set.
const Flags = packed struct(u8) {
    ready: bool = false,
    level: u7 = 0,
};

const Error = error{ OutOfMemory, TooLong };

pub fn copy(allocator: Allocator, text: []const u8) Error![]u8 {
    if (text.len > max_len) return error.TooLong;
    const out = try allocator.alloc(u8, text.len);
    errdefer allocator.free(out);
    @memcpy(out, text);
    return out;
}

fn sum(items: []const i24) i64 {
    var total: i64 = 0;
    for (items) |item| {
        total += @as(i64, item);
    }
    while (total > 1_000) : (total -= 1) {
        if (total == 500) break else continue;
    }
    return total;
}

test "copy" {
    const banner =
        \\multi-line
        \\string
    ;
    const c: u8 = 'z';
    const nl = '\n';
    const @"weird name" = 2.5e-3;
    var flags = Flags{};
    flags.ready = true;
    const value = switch (c) {
        'a'...'y' => null,
        else => undefined,
    };
    _ = .{ banner, nl, value, @"weird name", comptime sum(&.{}) };
    std.debug.print("{s}\n", .{"done"});
    unreachable;
}
