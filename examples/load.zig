const std = @import("std");

const dotenv = @import("dotenv");

const assert = std.debug.assert;

const Document = dotenv.DocumentType(
    .{ .entry_count_max = 64, .failure_count_max = 8, .text_bytes_max = 4096 },
    std.process.Environ.Map,
);

const source =
    \\PORT=8080
    \\CACHE=${HOME}/cache
    \\DEBUG
    \\not a binding
    \\
;

pub fn main(init: std.process.Init) !void {
    assert(init.environ_map.count() < std.math.maxInt(u32));
    assert(source.len <= dotenv.limits.source_bytes_max);

    var document: Document = undefined;

    const options = dotenv.Options{ .interpolate = true, .override = false };

    document.parse(init.environ_map, source, options) catch |err| {
        const diagnostic = document.diagnostic();

        std.debug.print("{d}:{d}: {s}\n", .{
            diagnostic.line,
            diagnostic.column,
            dotenv.message(err),
        });

        return err;
    };

    for (document.list()) |entry| {
        std.debug.print("{s}={s}\n", .{ entry.key, entry.value orelse "(unset)" });
    }

    var failures = document.failures();

    for (0..document.failure_count()) |_| {
        const position = failures.next() orelse break;

        std.debug.print("line {d} is not a binding\n", .{position.line});
    }

    const port = document.get("PORT") orelse return error.PortMissing;

    assert(std.mem.eql(u8, port.value orelse "", "8080"));
}
