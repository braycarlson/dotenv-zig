const std = @import("std");

const bounded = @import("bounded");
const document_module = @import("document.zig");
const scanner_module = @import("scanner.zig");
const text_module = @import("text.zig");

const assert = std.debug.assert;

const Document = document_module.Document;
const Options = document_module.Options;
const Scanner = scanner_module.Scanner;
const Statement = scanner_module.Statement;
const Variable = document_module.Variable;
const Variables = document_module.Variables;

const file_bytes_max: u32 = 4 * 1024 * 1024;
const json_values_bytes_max: u32 = 16 * 1024 * 1024;
const oracle_name = "python-dotenv 1.2.1";
const source_bytes_case_max: u32 = 1 << 20;
const statement_count_max: u32 = 1 << 16;
const usage_text = "usage: conformance <suite file>...\n";
const variable_count_max: u32 = 256;

const json_options: std.json.ParseOptions = .{
    .allocate = .alloc_always,
    .duplicate_field_behavior = .@"error",
    .ignore_unknown_fields = false,
    .max_value_len = null,
    .parse_numbers = false,
};

comptime {
    assert(json_values_bytes_max >= file_bytes_max);
    assert(source_bytes_case_max <= text_module.source_bytes_max);
    assert(statement_count_max >= 1024);
}

const Storage = document_module.StorageType(.{
    .entry_count_max = 4096,
    .failure_count_max = 4096,
    .text_bytes_max = 4 * source_bytes_case_max,
});

const Nullable = union(enum) {
    absent,
    text: []const u8,
};

const SuiteError = error{SuiteInvalid};

const Comparison = struct {
    actual: Nullable,
    expected: Nullable,
    what: []const u8,
};

const Tally = struct {
    failed: u32,
    passed: u32,
};

const Runner = struct {
    document: Document,
    json_values: [json_values_bytes_max]u8,
    name: []const u8,
    source: [source_bytes_case_max]u8,
    storage: Storage,
    suite: [file_bytes_max]u8,
    tally: Tally,
    text: [source_bytes_case_max]u8,
    unescaped: [source_bytes_case_max]u8,
    variables: bounded.ArrayType(Variable, variable_count_max),

    fn case_run(runner: *Runner, case: *const std.json.ObjectMap) SuiteError!bool {
        assert(case.count() > 0);
        assert(runner.tally.failed <= runner.tally.passed + runner.tally.failed);

        runner.name = try string_of(try member_of(case, "name"));

        const source = try runner.source_of(case);
        const outcome = try string_of(try member_of(case, "outcome"));
        const decoded = text_module.decode(&runner.text, source, .{ .diagnostic = null });

        if (std.mem.eql(u8, outcome, "utf8_invalid")) {
            const accepted = decoded catch |err| switch (err) {
                error.TextExhausted => return runner.mismatch("refused for want of space"),
                error.Utf8Invalid => return true,
            };

            assert(accepted.len <= source.len);

            return runner.mismatch("decoded although python-dotenv refused it");
        }

        if (!std.mem.eql(u8, outcome, "parsed")) return error.SuiteInvalid;

        const text = decoded catch return runner.mismatch("refused what python-dotenv decoded");
        const statements = try array_of(try member_of(case, "statements"));
        if (!try runner.statements_match(text, statements)) return false;

        try runner.environment_load(try object_of(try member_of(case, "environment")));

        const options = Options{
            .interpolate = try boolean_of(try member_of(case, "interpolate")),
            .override = try boolean_of(try member_of(case, "override")),
        };

        const values = try array_of(try member_of(case, "values"));
        if (!try runner.values_match(source, &options, values)) return false;
        return runner.loaded_match(try member_of(case, "loaded"));
    }

    fn source_of(runner: *Runner, case: *const std.json.ObjectMap) SuiteError![]const u8 {
        assert(case.count() > 0);
        assert(runner.source.len == source_bytes_case_max);

        if (case.get("source")) |source| return string_of(&source);

        const hex = try string_of(try member_of(case, "source_hex"));
        const result = std.fmt.hexToBytes(&runner.source, hex) catch return error.SuiteInvalid;

        assert(result.len * 2 == hex.len);

        return result;
    }

    fn statements_match(
        runner: *Runner,
        text: []const u8,
        expected: []const std.json.Value,
    ) SuiteError!bool {
        assert(text.len <= source_bytes_case_max);
        assert(expected.len <= statement_count_max);

        var scanner: Scanner = .init(text);

        for (expected) |*want| {
            const statement = scanner.next() orelse return runner.mismatch("statements end early");
            if (!try runner.statement_match(&statement, try array_of(want))) return false;
        }

        const extra = scanner.next();
        if (extra != null) return runner.mismatch("statements outnumber python-dotenv's");
        return true;
    }

    fn statement_match(
        runner: *Runner,
        statement: *const Statement,
        expected: []const std.json.Value,
    ) SuiteError!bool {
        assert(statement.original.len > 0);
        assert(expected.len < std.math.maxInt(u32));
        assert(runner.unescaped.len == source_bytes_case_max);

        if (expected.len != 5) return error.SuiteInvalid;

        const kind = try string_of(&expected[0]);

        const line = std.fmt.parseInt(u32, try number_of(&expected[4]), 10) catch {
            return error.SuiteInvalid;
        };

        const kind_matches = std.mem.eql(u8, kind, @tagName(statement.kind));
        if (!kind_matches) return runner.mismatch("kind differs");
        if (line != statement.line) return runner.mismatch("line differs");

        const original = Comparison{
            .actual = .{ .text = statement.original },
            .expected = try nullable_of(&expected[3]),
            .what = "original",
        };

        if (!runner.compare(&original)) return false;

        const bound = statement.kind == .binding;

        const key = Comparison{
            .actual = if (bound) .{ .text = statement.key } else .absent,
            .expected = try nullable_of(&expected[1]),
            .what = "key",
        };

        if (!runner.compare(&key)) return false;

        const value = Comparison{
            .actual = runner.value_unescaped(statement),
            .expected = try nullable_of(&expected[2]),
            .what = "value",
        };

        return runner.compare(&value);
    }

    fn value_unescaped(runner: *Runner, statement: *const Statement) Nullable {
        assert(statement.original.len > 0);
        assert(runner.unescaped.len == source_bytes_case_max);

        const found = statement.value orelse return .absent;
        const result: Nullable = .{ .text = found.unescape(&runner.unescaped) };

        return result;
    }

    fn environment_load(runner: *Runner, environment: *const std.json.ObjectMap) SuiteError!void {
        assert(environment.count() <= variable_count_max);
        assert(runner.variables.buffer.len == variable_count_max);

        runner.variables = .empty;

        for (environment.keys(), environment.values()) |name, *value| {
            const slot = runner.variables.push_slot() catch return error.SuiteInvalid;

            slot.* = .{ .name = name, .value = try string_of(value) };
        }
    }

    fn values_match(
        runner: *Runner,
        source: []const u8,
        options: *const Options,
        expected: []const std.json.Value,
    ) SuiteError!bool {
        assert(source.len <= source_bytes_case_max);
        assert(expected.len <= runner.storage.entries.len);

        const variables = Variables{ .list = runner.variables.slice() };
        const storage = runner.storage.storage();

        runner.document.parse(Variables, storage, &variables, source, options.*) catch |err| {
            std.debug.print("FAIL {s}: refused with {t}\n", .{ runner.name, err });

            return false;
        };

        const entries = runner.document.list();
        if (entries.len != expected.len) return runner.mismatch("entry count differs");

        for (entries, expected) |*entry, *want| {
            const pair = try array_of(want);
            if (pair.len != 2) return error.SuiteInvalid;

            const key = Comparison{
                .actual = .{ .text = entry.key },
                .expected = try nullable_of(&pair[0]),
                .what = "entry key",
            };

            const value = Comparison{
                .actual = if (entry.value) |found| .{ .text = found } else .absent,
                .expected = try nullable_of(&pair[1]),
                .what = "entry value",
            };

            if (!runner.compare(&key)) return false;
            if (!runner.compare(&value)) return false;
        }

        return true;
    }

    fn loaded_match(runner: *Runner, expected: *const std.json.Value) SuiteError!bool {
        assert(runner.document.entry_count <= runner.document.entries.len);
        assert(runner.variables.count <= variable_count_max);

        if (expected.* == .null) return true;

        const variables = Variables{ .list = runner.variables.slice() };

        for (try array_of(expected)) |*want| {
            const pair = try array_of(want);
            if (pair.len != 2) return error.SuiteInvalid;

            const key = try string_of(&pair[0]);
            const found = runner.document.loaded(Variables, &variables, key);

            const value = Comparison{
                .actual = if (found) |text| .{ .text = text } else .absent,
                .expected = try nullable_of(&pair[1]),
                .what = "loaded value",
            };

            if (!runner.compare(&value)) return false;
        }

        return true;
    }

    fn compare(runner: *const Runner, comparison: *const Comparison) bool {
        assert(comparison.what.len > 0);
        assert(runner.name.len > 0);

        const expected = switch (comparison.expected) {
            .absent => {
                if (comparison.actual == .absent) return true;
                return runner.mismatch(comparison.what);
            },
            .text => |text| text,
        };

        const actual = switch (comparison.actual) {
            .absent => return runner.mismatch(comparison.what),
            .text => |text| text,
        };

        if (std.mem.eql(u8, actual, expected)) return true;

        std.debug.print("FAIL {s}: {s} differs: got \"{f}\" expected \"{f}\"\n", .{
            runner.name,
            comparison.what,
            std.zig.fmtString(actual),
            std.zig.fmtString(expected),
        });

        return false;
    }

    fn mismatch(runner: *const Runner, what: []const u8) bool {
        assert(what.len > 0);
        assert(runner.name.len > 0);

        std.debug.print("FAIL {s}: {s}\n", .{ runner.name, what });

        return false;
    }
};

pub fn main(init: std.process.Init) !u8 {
    assert(init.minimal.args.vector.len < std.math.maxInt(u32));

    const arguments = try init.minimal.args.toSlice(init.arena.allocator());

    if (arguments.len < 2) {
        std.debug.print("{s}", .{usage_text});

        return 2;
    }

    const runner = try init.gpa.create(Runner);
    defer init.gpa.destroy(runner);

    runner.name = "";
    runner.tally = .{ .failed = 0, .passed = 0 };

    for (arguments[1..]) |path| try suite_run(init.io, runner, path);

    std.debug.print("conformance: {d} passed, {d} failed\n", .{
        runner.tally.passed,
        runner.tally.failed,
    });

    if (runner.tally.failed > 0) return 1;
    return 0;
}

fn suite_run(io: std.Io, runner: *Runner, path: []const u8) !void {
    assert(path.len > 0);
    assert(runner.tally.passed < std.math.maxInt(u32));

    const text = try std.Io.Dir.cwd().readFile(io, path, &runner.suite);
    if (text.len == runner.suite.len) return error.FileTooLarge;

    var values: std.heap.FixedBufferAllocator = .init(&runner.json_values);

    const suite = try std.json.parseFromSliceLeaky(
        std.json.Value,
        values.allocator(),
        text,
        json_options,
    );

    const root = try object_of(&suite);
    const oracle = try string_of(try member_of(root, "oracle"));
    if (!std.mem.eql(u8, oracle, oracle_name)) return error.SuiteInvalid;

    for (try array_of(try member_of(root, "cases"))) |*case| {
        if (try runner.case_run(try object_of(case))) {
            runner.tally.passed += 1;
        } else {
            runner.tally.failed += 1;
        }
    }
}

fn member_of(object: *const std.json.ObjectMap, name: []const u8) SuiteError!*const std.json.Value {
    assert(name.len > 0);
    assert(object.count() < std.math.maxInt(u32));

    const result = object.getPtr(name) orelse return error.SuiteInvalid;
    return result;
}

fn array_of(value: *const std.json.Value) SuiteError![]const std.json.Value {
    assert(@intFromPtr(value) != 0);

    const result = switch (value.*) {
        .array => |array| array.items,
        else => return error.SuiteInvalid,
    };

    assert(result.len < std.math.maxInt(u32));

    return result;
}

fn object_of(value: *const std.json.Value) SuiteError!*const std.json.ObjectMap {
    assert(@intFromPtr(value) != 0);

    const result = switch (value.*) {
        .object => |*object| object,
        else => return error.SuiteInvalid,
    };

    assert(result.count() < std.math.maxInt(u32));

    return result;
}

fn string_of(value: *const std.json.Value) SuiteError![]const u8 {
    assert(@intFromPtr(value) != 0);

    const result = switch (value.*) {
        .string => |string| string,
        else => return error.SuiteInvalid,
    };

    assert(result.len <= file_bytes_max);

    return result;
}

fn number_of(value: *const std.json.Value) SuiteError![]const u8 {
    assert(@intFromPtr(value) != 0);

    const result = switch (value.*) {
        .number_string => |number| number,
        else => return error.SuiteInvalid,
    };

    assert(result.len > 0);

    return result;
}

fn boolean_of(value: *const std.json.Value) SuiteError!bool {
    assert(@intFromPtr(value) != 0);

    return switch (value.*) {
        .bool => |boolean| boolean,
        else => error.SuiteInvalid,
    };
}

fn nullable_of(value: *const std.json.Value) SuiteError!Nullable {
    assert(@intFromPtr(value) != 0);

    const result: Nullable = switch (value.*) {
        .null => .absent,
        .string => |string| .{ .text = string },
        else => return error.SuiteInvalid,
    };

    return result;
}
