const std = @import("std");

const scanner_module = @import("scanner.zig");
const text_module = @import("text.zig");

const assert = std.debug.assert;

const DecodeError = text_module.DecodeError;
const Position = text_module.Position;
const Scanner = scanner_module.Scanner;
const Statement = scanner_module.Statement;
const Value = scanner_module.Statement.Value;

const source_bytes_max = text_module.source_bytes_max;

pub const CapacityError = error{
    EntriesExhausted,
    TextExhausted,
};

pub const SyntaxError = error{Utf8Invalid};
pub const Error = Document.Error || DecodeError;

pub const Capacity = struct {
    entry_count_max: u32,
    failure_count_max: u32,
    text_bytes_max: u32,
};

pub const Entry = struct {
    key: []const u8,
    value: ?[]const u8,
};

pub const Failures = struct {
    cursor: u32,
    document: *const Document,
    remaining: u32,

    pub fn next(failures: *Failures) ?Position {
        const kept = failures.document.failures_kept();

        assert(failures.cursor <= kept.len);
        assert(failures.remaining == kept.len - failures.cursor);

        if (failures.remaining == 0) return null;

        const result = kept[failures.cursor];

        failures.cursor += 1;
        failures.remaining -= 1;

        assert(result.line > 0);
        assert(result.column > 0);

        return result;
    }
};

pub const Options = struct {
    interpolate: bool = true,
    override: bool = false,
};

pub const Storage = struct {
    entries: []Entry,
    failures: []Position,
    text: []u8,
};

pub const Variable = struct {
    name: []const u8,
    value: []const u8,
};

pub const Variables = struct {
    list: []const Variable,

    pub fn lookup(variables: *const Variables, name: []const u8) ?[]const u8 {
        assert(variables.list.len < std.math.maxInt(u32));
        assert(name.len <= source_bytes_max);

        for (variables.list) |variable| {
            if (std.mem.eql(u8, variable.name, name)) return variable.value;
        }

        return null;
    }
};

pub fn StorageType(comptime capacity: Capacity) type {
    comptime assert(capacity.entry_count_max > 0);
    comptime assert(capacity.failure_count_max < std.math.maxInt(u32));
    comptime assert(capacity.text_bytes_max < std.math.maxInt(u32));

    return struct {
        entries: [capacity.entry_count_max]Entry,
        failures: [capacity.failure_count_max]Position,
        text: [capacity.text_bytes_max]u8,

        pub fn storage(fixed: *@This()) Storage {
            assert(fixed.entries.len == capacity.entry_count_max);
            assert(fixed.failures.len == capacity.failure_count_max);
            assert(fixed.text.len == capacity.text_bytes_max);

            return .{ .entries = &fixed.entries, .failures = &fixed.failures, .text = &fixed.text };
        }
    };
}

const Reference = struct {
    default: ?[]const u8,
    end: u32,
    name: []const u8,
};

pub const Document = struct {
    diagnostic: Position,
    entries: []Entry,
    entry_count: u32,
    failure_count: u32,
    failure_positions: []Position,
    options: Options,
    source: []const u8,
    text: []u8,
    text_used: u32,

    pub const Error = CapacityError || SyntaxError;

    pub fn parse(
        document: *Document,
        comptime Environment: type,
        storage: Storage,
        environment: *const Environment,
        source: []const u8,
        options: Options,
    ) Document.Error!void {
        comptime assert(@sizeOf(@TypeOf(options)) <= 16);

        assert(source.len <= source_bytes_max);
        assert(storage.entries.len < std.math.maxInt(u32));
        assert(storage.failures.len < std.math.maxInt(u32));
        assert(text_module.buffers_disjoint(&.{ .source = source, .target = storage.text }));

        comptime environment_check(Environment);

        document.* = .{
            .diagnostic = .{ .column = 0, .line = 0 },
            .entries = storage.entries,
            .entry_count = 0,
            .failure_count = 0,
            .failure_positions = storage.failures,
            .options = options,
            .source = "",
            .text = storage.text,
            .text_used = 0,
        };

        const decode_options = text_module.DecodeOptions{ .diagnostic = &document.diagnostic };
        const decoded = try text_module.decode(storage.text, source, decode_options);
        const copied = decoded.ptr == storage.text.ptr;

        document.source = decoded;
        document.text_used = if (copied) @intCast(decoded.len) else 0;

        var scanner: Scanner = .init(document.source);

        for (0..document.source.len + 1) |_| {
            const statement = scanner.next() orelse break;

            try document.statement_store(&statement, Environment, environment);
        }

        assert(scanner.offset == document.source.len);
        assert(document.entry_count <= document.entries.len);
        assert(document.diagnostic.line == 0);
    }

    pub fn list(document: *const Document) []const Entry {
        assert(document.entry_count <= document.entries.len);
        assert(document.text_used <= document.text.len);

        const result = document.entries[0..document.entry_count];

        assert(result.len == document.entry_count);

        return result;
    }

    pub fn get(document: *const Document, key: []const u8) ?Entry {
        assert(key.len <= source_bytes_max);
        assert(document.entry_count <= document.entries.len);

        const index = document.entry_find(key) orelse return null;
        const result = document.entries[index];

        assert(std.mem.eql(u8, result.key, key));

        return result;
    }

    pub fn loaded(
        document: *const Document,
        comptime Environment: type,
        environment: *const Environment,
        key: []const u8,
    ) ?[]const u8 {
        assert(key.len > 0);
        assert(document.entry_count <= document.entries.len);

        comptime environment_check(Environment);

        const entry = document.get(key);
        const declared: ?[]const u8 = if (entry) |found| found.value else null;
        const inherited = environment_lookup(Environment, environment, key);
        if (document.options.override) return declared orelse inherited;
        return inherited orelse declared;
    }

    pub fn failures(document: *const Document) Failures {
        assert(document.failure_count <= document.source.len);
        assert(document.failure_positions.len < std.math.maxInt(u32));

        const kept: u32 = @intCast(document.failures_kept().len);
        return .{ .cursor = 0, .document = document, .remaining = kept };
    }

    fn failures_kept(document: *const Document) []const Position {
        assert(document.failure_count <= document.source.len);
        assert(document.failure_positions.len < std.math.maxInt(u32));

        const count = @min(document.failure_count, document.failure_positions.len);
        return document.failure_positions[0..count];
    }

    fn statement_store(
        document: *Document,
        statement: *const Statement,
        comptime Environment: type,
        environment: *const Environment,
    ) Document.Error!void {
        assert(statement.original.len > 0);
        assert(statement.position.line >= statement.line);

        switch (statement.kind) {
            .binding => document.binding_store(statement, Environment, environment) catch |err| {
                document.diagnostic = statement.position;

                return err;
            },
            .failure => document.failure_record(statement),
            .trivia => {},
        }
    }

    fn failure_record(document: *Document, statement: *const Statement) void {
        assert(statement.kind == .failure);
        assert(document.failure_count < document.source.len);

        if (document.failure_count < document.failure_positions.len) {
            document.failure_positions[document.failure_count] = statement.position;
        }

        document.failure_count += 1;
    }

    fn binding_store(
        document: *Document,
        statement: *const Statement,
        comptime Environment: type,
        environment: *const Environment,
    ) Document.Error!void {
        assert(statement.kind == .binding);
        assert(statement.key.len > 0);

        const value = statement.value orelse return document.entry_store(statement.key, null);
        const unescaped = try document.value_unescape(&value);
        if (!document.options.interpolate) return document.entry_store(statement.key, unescaped);

        const resolved = try document.value_resolve(unescaped, Environment, environment);

        try document.entry_store(statement.key, resolved);
    }

    fn value_unescape(document: *Document, value: *const Value) Document.Error![]const u8 {
        assert(value.text.len <= document.source.len);
        assert(document.text_used <= document.text.len);

        if (!value.escapes_present()) return value.text;
        if (document.text.len - document.text_used < value.text.len) return error.TextExhausted;

        const result = value.unescape(document.text[document.text_used..]);

        document.text_used += @intCast(result.len);

        assert(result.len <= value.text.len);
        assert(document.text_used <= document.text.len);

        return result;
    }

    fn value_resolve(
        document: *Document,
        value: []const u8,
        comptime Environment: type,
        environment: *const Environment,
    ) Document.Error![]const u8 {
        assert(value.len < std.math.maxInt(u32));
        assert(document.options.interpolate);

        if (std.mem.find(u8, value, "${") == null) return value;

        const start = document.text_used;
        var cursor: u32 = 0;
        var position: u32 = 0;

        for (0..value.len + 1) |_| {
            const found = std.mem.findPos(u8, value, position, "${") orelse break;
            const begin: u32 = @intCast(found);

            const reference = reference_match(value, begin) orelse {
                position = begin + 1;

                continue;
            };

            const replacement = document.reference_lookup(&reference, Environment, environment);

            try document.text_append(value[cursor..begin]);
            try document.text_append(replacement);

            cursor = reference.end;
            position = reference.end;
        }

        try document.text_append(value[cursor..]);

        const result = document.text[start..document.text_used];

        assert(cursor <= value.len);
        assert(document.text_used <= document.text.len);

        return result;
    }

    fn reference_lookup(
        document: *const Document,
        reference: *const Reference,
        comptime Environment: type,
        environment: *const Environment,
    ) []const u8 {
        assert(reference.end > reference.name.len);
        assert(document.options.interpolate);

        const declared = document.entry_find(reference.name);
        const inherited = environment_lookup(Environment, environment, reference.name);

        if (document.options.override) {
            if (declared) |index| return document.entries[index].value orelse "";
            if (inherited) |found| return found;
        } else {
            if (inherited) |found| return found;
            if (declared) |index| return document.entries[index].value orelse "";
        }

        return reference.default orelse "";
    }

    fn text_append(document: *Document, bytes: []const u8) Document.Error!void {
        assert(document.text_used <= document.text.len);
        assert(bytes.len < std.math.maxInt(u32));

        if (document.text.len - document.text_used < bytes.len) return error.TextExhausted;

        @memcpy(document.text[document.text_used..][0..bytes.len], bytes);
        document.text_used += @intCast(bytes.len);

        assert(document.text_used <= document.text.len);
    }

    fn entry_find(document: *const Document, key: []const u8) ?u32 {
        assert(document.entry_count <= document.entries.len);
        assert(key.len <= source_bytes_max);

        for (document.entries[0..document.entry_count], 0..) |*entry, position| {
            if (!std.mem.eql(u8, entry.key, key)) continue;

            const result: u32 = @intCast(position);

            assert(result < document.entry_count);

            return result;
        }

        return null;
    }

    fn entry_store(document: *Document, key: []const u8, value: ?[]const u8) Document.Error!void {
        assert(key.len > 0);
        assert(document.entry_count <= document.entries.len);
        if (value) |text| assert(text.len < std.math.maxInt(u32));

        if (document.entry_find(key)) |index| {
            document.entries[index].value = value;

            return;
        }

        if (document.entry_count == document.entries.len) return error.EntriesExhausted;

        document.entries[document.entry_count] = .{ .key = key, .value = value };
        document.entry_count += 1;

        assert(document.entry_count <= document.entries.len);
    }
};

pub fn DocumentType(comptime capacity: Capacity, comptime Environment: type) type {
    comptime assert(capacity.entry_count_max > 0);
    comptime environment_check(Environment);

    return struct {
        document: Document,
        storage: StorageType(capacity),

        const Fixed = @This();
        pub const loaded = if (Environment == void) loaded_isolated else loaded_inherited;
        pub const parse = if (Environment == void) parse_isolated else parse_inherited;

        fn parse_isolated(fixed: *Fixed, source: []const u8, options: Options) Document.Error!void {
            comptime assert(@sizeOf(@TypeOf(options)) <= 16);

            assert(source.len <= source_bytes_max);
            assert(fixed.storage.entries.len == capacity.entry_count_max);

            return fixed.document.parse(void, fixed.storage.storage(), &{}, source, options);
        }

        fn parse_inherited(
            fixed: *Fixed,
            environment: *const Environment,
            source: []const u8,
            options: Options,
        ) Document.Error!void {
            comptime assert(@sizeOf(@TypeOf(options)) <= 16);

            assert(source.len <= source_bytes_max);
            assert(fixed.storage.entries.len == capacity.entry_count_max);

            const storage = fixed.storage.storage();
            return fixed.document.parse(Environment, storage, environment, source, options);
        }

        pub fn diagnostic(fixed: *const Fixed) Position {
            return fixed.document.diagnostic;
        }

        pub fn list(fixed: *const Fixed) []const Entry {
            return fixed.document.list();
        }

        pub fn get(fixed: *const Fixed, key: []const u8) ?Entry {
            assert(key.len <= source_bytes_max);

            return fixed.document.get(key);
        }

        fn loaded_isolated(fixed: *const Fixed, key: []const u8) ?[]const u8 {
            assert(key.len > 0);

            return fixed.document.loaded(void, &{}, key);
        }

        fn loaded_inherited(
            fixed: *const Fixed,
            environment: *const Environment,
            key: []const u8,
        ) ?[]const u8 {
            assert(key.len > 0);

            return fixed.document.loaded(Environment, environment, key);
        }

        pub fn failures(fixed: *const Fixed) Failures {
            return fixed.document.failures();
        }

        pub fn failure_count(fixed: *const Fixed) u32 {
            return fixed.document.failure_count;
        }
    };
}

pub fn message(err: Error) []const u8 {
    assert(@errorName(err).len > 0);

    const result: []const u8 = switch (err) {
        error.EntriesExhausted => "the document holds more keys than its capacity",
        error.TextExhausted => "the document holds more text than its capacity",
        error.Utf8Invalid => "invalid UTF-8",
    };

    assert(result.len > 0);

    return result;
}

fn environment_check(comptime Environment: type) void {
    if (Environment == void) return;
    if (Environment == std.process.Environ.Map) return;

    const container = switch (@typeInfo(Environment)) {
        .@"enum", .@"opaque", .@"struct", .@"union" => true,
        else => false,
    };

    if (container) {
        if (@hasDecl(Environment, "lookup")) return;
    }

    @compileError("the type " ++ @typeName(Environment) ++
        " is not void, std.process.Environ.Map, or a type with a lookup method");
}

fn environment_lookup(
    comptime Environment: type,
    environment: *const Environment,
    name: []const u8,
) ?[]const u8 {
    assert(name.len <= source_bytes_max);

    comptime environment_check(Environment);

    if (Environment == void) return null;
    if (Environment == std.process.Environ.Map) return environment.get(name);
    return environment.lookup(name);
}

fn reference_match(value: []const u8, begin: u32) ?Reference {
    assert(begin + 2 <= value.len);
    assert(std.mem.startsWith(u8, value[begin..], "${"));

    const name_start = begin + 2;
    const name_found = std.mem.findAnyPos(u8, value, name_start, "}:") orelse return null;
    const name_end: u32 = @intCast(name_found);
    const name = value[name_start..name_end];
    if (value[name_end] == '}') return .{ .default = null, .end = name_end + 1, .name = name };
    if (!std.mem.startsWith(u8, value[name_end..], ":-")) return null;

    const default_start = name_end + 2;
    const default_found = std.mem.findScalarPos(u8, value, default_start, '}') orelse return null;
    const default_end: u32 = @intCast(default_found);

    const result = Reference{
        .default = value[default_start..default_end],
        .end = default_end + 1,
        .name = name,
    };

    assert(result.end <= value.len);

    return result;
}

const testing = std.testing;

const test_capacity = Capacity{
    .entry_count_max = 64,
    .failure_count_max = 16,
    .text_bytes_max = 4096,
};

const test_capacity_small = Capacity{
    .entry_count_max = 2,
    .failure_count_max = 0,
    .text_bytes_max = 8,
};

const TestStorage = StorageType(test_capacity);

const Expectation = struct {
    actual: ?[]const u8,
    expected: ?[]const u8,
};

const TestCase = struct {
    environment: []const Variable,
    expected: []const Entry,
    interpolate: bool,
    source: []const u8,
};

fn test_parse(
    document: *Document,
    storage: *TestStorage,
    source: []const u8,
    options: *const Options,
    variables: *const Variables,
) Document.Error!void {
    assert(source.len <= storage.text.len);
    assert(variables.list.len <= 16);

    try document.parse(Variables, storage.storage(), variables, source, options.*);
}

fn test_expect(document: *const Document, expected: []const Entry) !void {
    assert(expected.len <= 64);
    assert(document.entry_count <= document.entries.len);

    const entries = document.list();

    try testing.expectEqual(expected.len, entries.len);

    for (expected, entries) |want, entry| {
        try testing.expectEqualStrings(want.key, entry.key);
        try test_expect_value(&.{ .actual = entry.value, .expected = want.value });
    }
}

fn test_expect_value(expectation: *const Expectation) !void {
    if (expectation.expected) |text| assert(text.len <= 4096);
    if (expectation.actual) |text| assert(text.len <= 4096 * 4);

    const actual = expectation.actual;

    const want = expectation.expected orelse {
        return testing.expectEqual(@as(?[]const u8, null), actual);
    };

    try testing.expectEqualStrings(want, actual orelse return error.TestUnexpectedResult);
}

const environment_b_c = [_]Variable{.{ .name = "b", .value = "c" }};
const environment_a_b = [_]Variable{.{ .name = "a", .value = "b" }};

const upstream_interpolation_cases = [_]TestCase{
    .{
        .environment = &environment_b_c,
        .expected = &.{.{ .key = "a", .value = "$b" }},
        .interpolate = false,
        .source = "a=$b",
    },
    .{
        .environment = &environment_b_c,
        .expected = &.{.{ .key = "a", .value = "$b" }},
        .interpolate = true,
        .source = "a=$b",
    },
    .{
        .environment = &environment_b_c,
        .expected = &.{.{ .key = "a", .value = "${b}" }},
        .interpolate = false,
        .source = "a=${b}",
    },
    .{
        .environment = &environment_b_c,
        .expected = &.{.{ .key = "a", .value = "c" }},
        .interpolate = true,
        .source = "a=${b}",
    },
    .{
        .environment = &environment_b_c,
        .expected = &.{.{ .key = "a", .value = "${b:-d}" }},
        .interpolate = false,
        .source = "a=${b:-d}",
    },
    .{
        .environment = &environment_b_c,
        .expected = &.{.{ .key = "a", .value = "c" }},
        .interpolate = true,
        .source = "a=${b:-d}",
    },
    .{
        .environment = &.{},
        .expected = &.{ .{ .key = "b", .value = "c" }, .{ .key = "a", .value = "c" } },
        .interpolate = true,
        .source = "b=c\na=${b}",
    },
    .{
        .environment = &.{},
        .expected = &.{.{ .key = "a", .value = "" }},
        .interpolate = true,
        .source = "a=${b}",
    },
    .{
        .environment = &.{},
        .expected = &.{.{ .key = "a", .value = "d" }},
        .interpolate = true,
        .source = "a=${b:-d}",
    },
    .{
        .environment = &environment_b_c,
        .expected = &.{.{ .key = "a", .value = "c" }},
        .interpolate = true,
        .source = "a=\"${b}\"",
    },
    .{
        .environment = &environment_b_c,
        .expected = &.{.{ .key = "a", .value = "c" }},
        .interpolate = true,
        .source = "a='${b}'",
    },
    .{
        .environment = &environment_b_c,
        .expected = &.{.{ .key = "a", .value = "xcy" }},
        .interpolate = true,
        .source = "a=x${b}y",
    },
    .{
        .environment = &environment_a_b,
        .expected = &.{.{ .key = "a", .value = "b" }},
        .interpolate = true,
        .source = "a=${a}",
    },
    .{
        .environment = &.{},
        .expected = &.{.{ .key = "a", .value = "" }},
        .interpolate = true,
        .source = "a=${a}",
    },
    .{
        .environment = &environment_a_b,
        .expected = &.{.{ .key = "a", .value = "b" }},
        .interpolate = true,
        .source = "a=${a:-c}",
    },
    .{
        .environment = &.{},
        .expected = &.{.{ .key = "a", .value = "c" }},
        .interpolate = true,
        .source = "a=${a:-c}",
    },
    .{
        .environment = &environment_b_c,
        .expected = &.{.{ .key = "a", .value = "cc" }},
        .interpolate = true,
        .source = "a=${b}${b}",
    },
    .{
        .environment = &environment_b_c,
        .expected = &.{ .{ .key = "b", .value = "d" }, .{ .key = "a", .value = "d" } },
        .interpolate = true,
        .source = "b=d\na=${b}",
    },
    .{
        .environment = &.{},
        .expected = &.{ .{ .key = "a", .value = "c" }, .{ .key = "d", .value = "c" } },
        .interpolate = true,
        .source = "a=b\na=c\nd=${a}",
    },
    .{
        .environment = &.{},
        .expected = &.{
            .{ .key = "a", .value = "b" },
            .{ .key = "c", .value = "e" },
            .{ .key = "d", .value = "e" },
        },
        .interpolate = true,
        .source = "a=b\nc=${a}\nd=e\nc=${d}",
    },
};

test "the upstream interpolation cases resolve to the values python-dotenv's tests state" {
    const storage = try testing.allocator.create(TestStorage);
    defer testing.allocator.destroy(storage);

    var document: Document = undefined;

    for (upstream_interpolation_cases) |case| {
        const variables = Variables{ .list = case.environment };
        const options = Options{ .interpolate = case.interpolate, .override = true };

        try test_parse(&document, storage, case.source, &options, &variables);
        try test_expect(&document, case.expected);
    }
}

test "the environment wins without override and loses with it, both in values and in loaded" {
    const storage = try testing.allocator.create(TestStorage);
    defer testing.allocator.destroy(storage);

    const environment = [_]Variable{
        .{ .name = "A", .value = "env" },
        .{ .name = "C", .value = "inherited" },
    };

    const variables = Variables{ .list = &environment };
    const source = "A=file\nB=${A}\nC\n";
    const kept = Options{ .interpolate = true, .override = false };

    var document: Document = undefined;

    try test_parse(&document, storage, source, &kept, &variables);

    try test_expect(&document, &.{
        .{ .key = "A", .value = "file" },
        .{ .key = "B", .value = "env" },
        .{ .key = "C", .value = null },
    });

    const a_kept = document.loaded(Variables, &variables, "A");
    const b_kept = document.loaded(Variables, &variables, "B");
    const c_kept = document.loaded(Variables, &variables, "C");
    const d_kept = document.loaded(Variables, &variables, "D");

    try test_expect_value(&.{ .actual = a_kept, .expected = "env" });
    try test_expect_value(&.{ .actual = b_kept, .expected = "env" });
    try test_expect_value(&.{ .actual = c_kept, .expected = "inherited" });
    try test_expect_value(&.{ .actual = d_kept, .expected = null });

    const overridden = Options{ .interpolate = true, .override = true };

    try test_parse(&document, storage, source, &overridden, &variables);

    try test_expect(&document, &.{
        .{ .key = "A", .value = "file" },
        .{ .key = "B", .value = "file" },
        .{ .key = "C", .value = null },
    });

    const a_overridden = document.loaded(Variables, &variables, "A");
    const c_overridden = document.loaded(Variables, &variables, "C");

    try test_expect_value(&.{ .actual = a_overridden, .expected = "file" });
    try test_expect_value(&.{ .actual = c_overridden, .expected = "inherited" });
}

test "a repeated key keeps its first position and a key alone has no value" {
    const storage = try testing.allocator.create(TestStorage);
    defer testing.allocator.destroy(storage);

    const variables = Variables{ .list = &.{} };
    const options = Options{ .interpolate = true, .override = true };
    const source = "A=1\r\nB=\"x\r\ny\"\rA=3\r\nFLAG # set\n";

    var document: Document = undefined;

    try test_parse(&document, storage, source, &options, &variables);

    try test_expect(&document, &.{
        .{ .key = "A", .value = "3" },
        .{ .key = "B", .value = "x\ny" },
        .{ .key = "FLAG", .value = null },
    });

    const entry = document.get("B") orelse return error.TestUnexpectedResult;

    try test_expect_value(&.{ .actual = entry.value, .expected = "x\ny" });
    try testing.expectEqual(@as(?Entry, null), document.get("MISSING"));
}

test "storage limits and invalid UTF-8 are reported as errors" {
    const Small = StorageType(test_capacity_small);

    var small: Small = undefined;
    var document: Document = undefined;

    const variables = Variables{ .list = &.{} };
    const options = Options{ .interpolate = true, .override = true };

    try document.parse(Variables, small.storage(), &variables, "A=1\nB=2\nA=3\n", options);
    try testing.expectEqual(@as(u32, 2), document.entry_count);

    const three = "A=1\nB=2\nC=3\n";
    const many = document.parse(Variables, small.storage(), &variables, three, options);

    try testing.expectError(error.EntriesExhausted, many);

    const expanding = "A=12345\nB=${A}${A}\n";
    const expanded = document.parse(Variables, small.storage(), &variables, expanding, options);

    try testing.expectError(error.TextExhausted, expanded);

    const crlf = document.parse(Variables, small.storage(), &variables, "A=12345\r\n", options);

    try testing.expectError(error.TextExhausted, crlf);

    const invalid = document.parse(Variables, small.storage(), &variables, "A=\xff\n", options);

    try testing.expectError(error.Utf8Invalid, invalid);
}

test DocumentType {
    const Config = DocumentType(
        .{ .entry_count_max = 16, .failure_count_max = 4, .text_bytes_max = 1024 },
        Variables,
    );

    const inherited = [_]Variable{.{ .name = "HOME", .value = "/home/warbler" }};
    const variables = Variables{ .list = &inherited };

    var config: Config = undefined;

    try config.parse(&variables, "PORT=8080\nCACHE=${HOME}/cache\n", .{});

    const port = config.get("PORT") orelse return error.PortMissing;
    const cache = config.get("CACHE") orelse return error.CacheMissing;

    try testing.expectEqualStrings("8080", port.value orelse return error.PortEmpty);
    const cache_value = cache.value orelse return error.CacheEmpty;

    try testing.expectEqualStrings("/home/warbler/cache", cache_value);
    try testing.expectEqual(@as(usize, 2), config.list().len);
    try testing.expectEqualStrings("/home/warbler", config.loaded(&variables, "HOME") orelse "");

    const refused = config.parse(&variables, "PORT=8080\nNAME=\xff\n", .{});

    try testing.expectError(error.Utf8Invalid, refused);
    try testing.expectEqual(Position{ .column = 6, .line = 2 }, config.diagnostic());
}

test Document {
    const storage = try testing.allocator.create(TestStorage);
    defer testing.allocator.destroy(storage);

    const variables = Variables{ .list = &.{} };

    var document: Document = undefined;

    try document.parse(Variables, storage.storage(), &variables, "A=1\nB=${A}2\n", .{});

    const entry = document.get("B") orelse return error.KeyMissing;

    try testing.expectEqualStrings("12", entry.value orelse return error.ValueEmpty);

    const refused = document.parse(Variables, storage.storage(), &variables, "A=\xff\n", .{});

    try testing.expectError(error.Utf8Invalid, refused);
}

test "a failed parse leaves the position of what failed in diagnostic" {
    const Small = StorageType(test_capacity_small);

    var small: Small = undefined;
    var document: Document = undefined;

    const options = Options{ .interpolate = true, .override = false };
    const three = "A=1\n\nB=2\n \t export C=3\n";
    const many = document.parse(void, small.storage(), &{}, three, options);

    try testing.expectError(error.EntriesExhausted, many);
    try testing.expectEqual(Position{ .column = 11, .line = 4 }, document.diagnostic);

    const expanded = document.parse(void, small.storage(), &{}, "A=12345\n  B=${A}${A}\n", options);

    try testing.expectError(error.TextExhausted, expanded);
    try testing.expectEqual(Position{ .column = 3, .line = 2 }, document.diagnostic);

    const quoted = "A=1\n B=\"x\\t1234567\"\n";
    const escaped = document.parse(void, small.storage(), &{}, quoted, options);

    try testing.expectError(error.TextExhausted, escaped);
    try testing.expectEqual(Position{ .column = 2, .line = 2 }, document.diagnostic);

    const crlf = document.parse(void, small.storage(), &{}, "A=1\nB=12345\r\n", options);

    try testing.expectError(error.TextExhausted, crlf);
    try testing.expectEqual(Position{ .column = 8, .line = 2 }, document.diagnostic);

    const invalid = document.parse(void, small.storage(), &{}, "A=1\nB=\u{e9}\xff\n", options);

    try testing.expectError(error.Utf8Invalid, invalid);
    try testing.expectEqual(Position{ .column = 4, .line = 2 }, document.diagnostic);

    try document.parse(void, small.storage(), &{}, "A=1\n", options);
    try testing.expectEqual(Position{ .column = 0, .line = 0 }, document.diagnostic);
}

test "each failed statement is counted and the first ones keep their positions" {
    const source = "=1\n\n  KEY junk\nA=1\nexport  =2\n\u{3000}\u{e9} \u{e9}\n";

    const expected = [_]Position{
        .{ .column = 1, .line = 1 },
        .{ .column = 3, .line = 3 },
        .{ .column = 9, .line = 5 },
        .{ .column = 2, .line = 6 },
    };

    const options = Options{ .interpolate = false, .override = false };

    var entries: [4]Entry = undefined;
    var positions: [expected.len]Position = undefined;
    var text: [64]u8 = undefined;
    var document: Document = undefined;

    for (0..expected.len + 1) |kept| {
        const storage = Storage{
            .entries = &entries,
            .failures = positions[0..kept],
            .text = &text,
        };

        try document.parse(void, storage, &{}, source, options);
        try testing.expectEqual(@as(u32, expected.len), document.failure_count);

        var failures = document.failures();

        for (expected[0..kept]) |want| {
            const position = failures.next();

            try testing.expectEqual(@as(?Position, want), position);
        }

        const after = failures.next();

        try testing.expectEqual(@as(?Position, null), after);
        try testing.expectEqual(@as(usize, 1), document.list().len);
    }
}

test "an environment is void, the process environment map, or a type with a lookup method" {
    var environ_map = std.process.Environ.Map.init(testing.allocator);
    defer environ_map.deinit();

    try environ_map.put("HOME", "/home/warbler");

    const Inherited = DocumentType(test_capacity, std.process.Environ.Map);
    const Isolated = DocumentType(test_capacity, void);
    const inherited = try testing.allocator.create(Inherited);
    defer testing.allocator.destroy(inherited);

    const isolated = try testing.allocator.create(Isolated);
    defer testing.allocator.destroy(isolated);

    const source = "HOME=/root\nCACHE=${HOME}/cache\n";
    const options = Options{ .interpolate = true, .override = false };

    try inherited.parse(&environ_map, source, options);
    try isolated.parse(source, options);

    const inherited_cache = inherited.get("CACHE") orelse return error.CacheMissing;
    const isolated_cache = isolated.get("CACHE") orelse return error.CacheMissing;
    const inherited_home = inherited.loaded(&environ_map, "HOME");

    try test_expect_value(&.{ .actual = inherited_cache.value, .expected = "/home/warbler/cache" });
    try test_expect_value(&.{ .actual = isolated_cache.value, .expected = "/root/cache" });
    try test_expect_value(&.{ .actual = inherited_home, .expected = "/home/warbler" });
    try test_expect_value(&.{ .actual = isolated.loaded("HOME"), .expected = "/root" });
    try test_expect_value(&.{ .actual = isolated.loaded("PATH"), .expected = null });
}

test "each error has a message of its own" {
    const names = comptime @typeInfo(Error).error_set.error_names.?;

    inline for (names, 0..) |name, index| {
        const text = message(@field(Error, name));

        try testing.expect(text.len > 0);

        inline for (names[0..index]) |earlier| {
            try testing.expect(!std.mem.eql(u8, text, message(@field(Error, earlier))));
        }
    }
}

test Failures {
    const Config = DocumentType(
        .{ .entry_count_max = 4, .failure_count_max = 4, .text_bytes_max = 64 },
        void,
    );

    var config: Config = undefined;

    try config.parse("A=1\nnot a binding\n  B=2\n=3\n", .{});

    var failures = config.failures();
    var lines: [2]u32 = undefined;

    for (0..config.failure_count()) |index| {
        const position = failures.next() orelse break;

        lines[index] = position.line;
    }

    try testing.expectEqual(@as(u32, 2), config.failure_count());
    try testing.expectEqual([2]u32{ 2, 4 }, lines);
}

test message {
    const Config = DocumentType(
        .{ .entry_count_max = 1, .failure_count_max = 0, .text_bytes_max = 64 },
        void,
    );

    var config: Config = undefined;
    var buffer: [64]u8 = undefined;
    var line: []const u8 = "";

    config.parse("A=1\n  B=2\n", .{}) catch |err| {
        const diagnostic = config.diagnostic();

        line = try std.mem.print(&buffer, "{d}:{d}: {s}", .{
            diagnostic.line,
            diagnostic.column,
            message(err),
        });
    };

    try testing.expectEqualStrings("2:3: the document holds more keys than its capacity", line);
}
