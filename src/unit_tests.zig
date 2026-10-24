const std = @import("std");

const assert = std.debug.assert;

comptime {
    _ = @import("bounded.zig");
    _ = @import("conformance.zig");
    _ = @import("document.zig");
    _ = @import("dotenv.zig");
    _ = @import("fuzz_tests.zig");
    _ = @import("scanner.zig");
    _ = @import("text.zig");
    _ = @import("tidy.zig");
}

test "every public declaration compiles" {
    const dotenv = @import("dotenv.zig");

    const capacity = dotenv.Capacity{
        .entry_count_max = 16,
        .failure_count_max = 4,
        .text_bytes_max = 1024,
    };

    const Document = dotenv.DocumentType(capacity, dotenv.Variables);
    const DocumentInherited = dotenv.DocumentType(capacity, std.process.Environ.Map);
    const DocumentIsolated = dotenv.DocumentType(capacity, void);

    comptime assert(@hasDecl(dotenv, "DocumentType"));
    comptime assert(@hasDecl(dotenv, "Scanner"));

    std.testing.refAllDecls(dotenv);
    std.testing.refAllDecls(dotenv.Document);
    std.testing.refAllDecls(dotenv.Failures);
    std.testing.refAllDecls(dotenv.Scanner);
    std.testing.refAllDecls(dotenv.Statement);
    std.testing.refAllDecls(dotenv.limits);
    std.testing.refAllDecls(Document);
    std.testing.refAllDecls(DocumentInherited);
    std.testing.refAllDecls(DocumentIsolated);
}
