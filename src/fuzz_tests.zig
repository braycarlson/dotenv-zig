const std = @import("std");

const bounded = @import("bounded");
const document_module = @import("document.zig");
const scanner_module = @import("scanner.zig");
const text_module = @import("text.zig");

const assert = std.debug.assert;
const testing = std.testing;

const Document = document_module.Document;
const Entry = document_module.Entry;
const Kind = scanner_module.Statement.Kind;
const Options = document_module.Options;
const Position = text_module.Position;
const Prng = std.Random.DefaultPrng;
const Quote = scanner_module.Statement.Quote;
const ReferenceFrame = scanner_module.ReferenceFrame;
const Scanner = scanner_module.Scanner;
const Statement = scanner_module.Statement;
const Value = scanner_module.Statement.Value;
const Variable = document_module.Variable;
const Variables = document_module.Variables;

const Fuzzer = enum {
    capacity,
    model,
    mutation,
    smoke,
};

const Campaign = struct {
    events_max: u32,
    seed: u64,
};

const arguments_bytes_max: u32 = 4096;
const codepoint_count_max: u32 = 12;
const dense_bytes_max: u32 = 1024;
const dense_failure_count_max: u32 = 256;
const dense_fill_max: u32 = dense_bytes_max - 64;
const dense_key_count_max: u32 = 64;
const dense_quoted_bytes_max: u32 = 480;
const dense_unit_count_max: u32 = 160;
const entry_count_max: u32 = 4096;
const events_max_default: u32 = 20_000;
const events_max_smoke: u32 = 512;
const line_count_max: u32 = 24;
const mutation_count_max: u32 = 8;
const reference_count_max: u32 = 2;
const seed_smoke: u64 = 0x5eed;
const short_bytes_max: u32 = 2048;
const text_bytes_max: u32 = 64 * 1024;
const usage_text = "usage: fuzz <capacity|model|mutation|smoke> [seed]\n";

comptime {
    assert(dense_bytes_max <= text_bytes_max);
    assert(dense_key_count_max * 3 <= dense_fill_max);
    assert(dense_failure_count_max * 3 <= dense_fill_max);
    assert(dense_quoted_bytes_max + 16 <= dense_fill_max);
    assert(events_max_smoke < events_max_default);
    assert(line_count_max * short_bytes_max * 2 < text_bytes_max * 4);
    assert(text_bytes_max <= text_module.source_bytes_max);
}

const Short = bounded.BufferType(short_bytes_max);
const Text = bounded.ArrayType(u8, text_bytes_max);

const Storage = document_module.StorageType(.{
    .entry_count_max = entry_count_max,
    .failure_count_max = entry_count_max,
    .text_bytes_max = 4 * text_bytes_max,
});

const DenseStorage = document_module.StorageType(.{
    .entry_count_max = @divFloor(dense_bytes_max, 2) + 1,
    .failure_count_max = @divFloor(dense_bytes_max, 2) + 1,
    .text_bytes_max = 2 * dense_bytes_max,
});

const DenseShape = enum {
    entries,
    failures,
    mixed,
    text,
};

const LineShape = enum {
    binding,
    blank,
    comment,
    declaration,
    failure,
};

const ModelEntry = struct {
    key: Short,
    value: ?Short,
};

const ModelKey = struct {
    name: []const u8,
    spelling: []const u8,
};

const ModelStatement = struct {
    key: Short,
    kind: Kind,
};

const Model = struct {
    entries: bounded.ArrayType(ModelEntry, line_count_max),
    environment: bounded.ArrayType(Variable, environment_table.len),
    options: Options,
    statements: bounded.ArrayType(ModelStatement, line_count_max + 1),
    trailing: bool,
};

const Expectation = struct {
    actual: ?[]const u8,
    expected: ?[]const u8,
};

const EntriesExpectation = struct {
    actual: []const Entry,
    expected: []const Entry,
};

const Span = struct {
    inner: []const u8,
    outer: []const u8,
};

const ValueWriter = struct {
    quote: Quote,
    reference_count: u32,
    start: u32,
    value: Short,
};

const Witness = struct {
    entries: bool,
    failures: bool,
    text: bool,
};

const State = struct {
    decoded: [text_bytes_max]u8,
    dense_rule: DenseStorage,
    dense_shrunk: DenseStorage,
    document: Document,
    model: Model,
    prng: Prng,
    shrunk: Document,
    stack: [text_bytes_max + 1]ReferenceFrame,
    storage: Storage,
    text: Text,
    unescaped: [text_bytes_max]u8,
    witness: Witness,
    writer: ValueWriter,
};

const environment_table = [_]Variable{
    .{ .name = "A", .value = "env" },
    .{ .name = "E", .value = "" },
    .{ .name = "B_2", .value = "x y" },
    .{ .name = "q k", .value = "${A}" },
};

const model_keys = [_]ModelKey{
    .{ .name = "A", .spelling = "A" },
    .{ .name = "B_2", .spelling = "B_2" },
    .{ .name = "a.b", .spelling = "a.b" },
    .{ .name = "x-y", .spelling = "x-y" },
    .{ .name = "1K", .spelling = "1K" },
    .{ .name = "\u{e9}t\u{e9}", .spelling = "\u{e9}t\u{e9}" },
    .{ .name = "[x]", .spelling = "[x]" },
    .{ .name = "q k", .spelling = "'q k'" },
    .{ .name = "a=b", .spelling = "'a=b'" },
    .{ .name = "#h", .spelling = "'#h'" },
};

const failure_lines = [_][]const u8{
    "=value",
    "a: b",
    "KEY junk",
    "export  =1",
    "''=1",
    "A=\"x\"junk",
    "B='y' z",
    "K\u{a0}V=1",
};

const bare_alphabet = [_][]const u8{
    "a",
    "c",
    "X",
    "0",
    "9",
    "_",
    ".",
    "/",
    ":",
    "@",
    "%",
    "+",
    "-",
    "!",
    "(",
    ";",
    "$",
    "#",
    "\u{e9}",
    "\u{4e2d}",
};

const double_alphabet = [_][]const u8{
    "a",
    "Z",
    " ",
    "#",
    "'",
    "\"",
    "\\",
    "\n",
    "\t",
    "\r",
    "$",
    "\u{e9}",
    "\u{1f600}",
};

const single_alphabet = [_][]const u8{
    "a",
    "Z",
    " ",
    "#",
    "\"",
    "'",
    "\\",
    "\n",
    "$",
    "\u{e9}",
};

const mutation_tokens = [_][]const u8{
    "=",
    "#",
    "'",
    "\"",
    "\\",
    " ",
    "\t",
    "\n",
    "\r",
    "$",
    "{",
    "}",
    ":",
    "-",
    "x",
    "A",
    "\x00",
    "\x0b",
    "\u{a0}",
    "\u{2028}",
    "\u{3000}",
    "\u{e9}",
    "\u{feff}",
    "export ",
    "${A}",
    "\xff",
};

const dense_keys = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-";
const dense_separators = [_][]const u8{ "\n", "\r", "\r\n" };
const dense_endings = [_][]const u8{ "", "\n", "\r", "\r\n" };

const dense_units = [_][]const u8{
    "=",
    "\n",
    "\r",
    "\r\n",
    " ",
    "export ",
    "#c",
    "a b",
    "K=\"\\\\\"",
    "K='\\''",
    "K=\"x\\ny\"",
    "${A}",
    "\u{e9}",
    "\u{3000}",
};

const blank_texts = [_][]const u8{ "", " ", "\t", " \t ", "\u{3000}" };
const comment_suffixes = [_][]const u8{ "", " ", " # note", "#note", "\t# note 'q' \"d\"" };
const default_alphabet = [_][]const u8{ "d", "x", " ", "$" };
const exports = [_][]const u8{ "", "", "", "export ", "export\t\t" };
const indents = [_][]const u8{ "", "", " ", "\t", "\u{a0}" };
const line_endings = [_][]const u8{ "\n", "\n", "\r\n", "\r" };
const reference_names = [_][]const u8{ "A", "B_2", "q k", "E", "M", "a.b" };
const spaces = [_][]const u8{ "", "", " ", "\t" };

const corpus = [_][]const u8{
    "A=1\nB = 2\nexport C=\"3\"\nD='4'\nE=5 # c\n",
    "PASSWORD=\"a\\\"b\"\nMESSAGE=\"line1\\nline2\"\nCERT=\"first\nsecond\"\n",
    "USER=example\nURL=postgres://${USER}@db/${NAME:-app}\n",
    "A=\"a\\\"\nB=2\nC='a\\'b\\''\n'k y'=1\n",
    "\u{feff}# c\n\n\nexport A = 'x' # y\n=\nKEY junk\nK2 # c\n",
    "A= #comment\nB=x\u{a0}#c\nC=x\u{2028}y\n",
    "A=${A}x\nA=${A}y\nB=$${A}\nC=${A${B}}\nD=${:-z}\n",
    "A=\"1\r\n2\"\r\nB=3\r\nC=4\rD=5",
    "NAME=app\nCERT=\"first\nDEBUG=False\nKEY=\"abc\"\n",
};

pub fn main(init: std.process.Init) !void {
    assert(init.minimal.args.vector.len < std.math.maxInt(u32));

    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len < 2) return usage();
    if (arguments.len > 3) return usage();

    const fuzzer = std.meta.stringToEnum(Fuzzer, arguments[1]) orelse return usage();
    const seed_text = if (arguments.len == 3) arguments[2] else "";
    const state = try init.gpa.create(State);
    defer init.gpa.destroy(state);

    if (fuzzer == .smoke) {
        if (seed_text.len > 0) return usage();

        for (std.enums.values(Fuzzer)) |each| {
            if (each == .smoke) continue;

            try run(state, each, &.{ .events_max = events_max_smoke, .seed = seed_smoke });
        }

        return;
    }

    const seed = if (seed_text.len == 0) seed_random(init.io) else try seed_parse(seed_text);

    try run(state, fuzzer, &.{ .events_max = events_max_default, .seed = seed });
}

fn usage() error{ArgumentsInvalid} {
    assert(usage_text.len > 0);
    assert(arguments_bytes_max > 0);

    std.debug.print("{s}", .{usage_text});

    return error.ArgumentsInvalid;
}

fn seed_parse(text: []const u8) error{ArgumentsInvalid}!u64 {
    assert(text.len > 0);
    assert(text.len <= arguments_bytes_max);

    const result = std.fmt.parseInt(u64, text, 10) catch return usage();
    return result;
}

fn seed_random(io: std.Io) u64 {
    var result: u64 = 0;

    io.random(std.mem.asBytes(&result));

    assert(@sizeOf(u64) == 8);

    return result;
}

fn run(state: *State, fuzzer: Fuzzer, campaign: *const Campaign) !void {
    assert(fuzzer != .smoke);
    assert(campaign.events_max > 0);

    std.debug.print("fuzz {t}: seed={d} events_max={d}\n", .{
        fuzzer,
        campaign.seed,
        campaign.events_max,
    });

    state.prng = .init(campaign.seed);
    state.witness = .{ .entries = false, .failures = false, .text = false };

    for (0..campaign.events_max) |_| {
        switch (fuzzer) {
            .capacity => try capacity_event(state),
            .model => try model_event(state),
            .mutation => try mutation_event(state),
            .smoke => unreachable,
        }
    }

    if (fuzzer == .capacity) try witness_check(&state.witness);
}

fn witness_check(witness: *const Witness) error{WitnessMissing}!void {
    assert(dense_bytes_max > 0);
    assert(dense_fill_max < dense_bytes_max);

    if (!witness.entries) return witness_missing("entries");
    if (!witness.failures) return witness_missing("failures");
    if (!witness.text) return witness_missing("text");
}

fn witness_missing(bound: []const u8) error{WitnessMissing} {
    assert(bound.len > 0);
    assert(bound.len <= 16);

    std.debug.print("fuzz capacity: no event reached the {s} bound\n", .{bound});

    return error.WitnessMissing;
}

fn pick(prng: *Prng, items: []const []const u8) []const u8 {
    assert(items.len > 0);
    assert(items.len < std.math.maxInt(u32));

    const result = items[prng.random().uintLessThan(u32, @intCast(items.len))];

    assert(result.len <= 64);

    return result;
}

fn mutation_event(state: *State) !void {
    assert(corpus.len > 0);
    assert(state.text.buffer.len == text_bytes_max);

    const random = state.prng.random();

    state.text = .empty;

    try state.text.push_slice(corpus[random.uintLessThan(u32, corpus.len)]);

    const mutation_count = random.intRangeAtMost(u32, 1, mutation_count_max);

    for (0..mutation_count) |_| text_mutate(&state.prng, &state.text);

    const source = state.text.slice();

    var diagnostic: Position = undefined;

    const decode_options = text_module.DecodeOptions{ .diagnostic = &diagnostic };

    const decoded = text_module.decode(&state.decoded, source, decode_options) catch |err| {
        switch (err) {
            error.TextExhausted => unreachable,
            error.Utf8Invalid => {
                try testing.expect(!std.unicode.utf8ValidateSlice(source));
                try invalid_audit(state, source, diagnostic);

                return;
            },
        }
    };

    try statements_audit(state, decoded);

    const options = Options{ .interpolate = random.boolean(), .override = random.boolean() };
    const parsed = try document_audit(state, source, &options);
    if (!parsed) return try diagnostic_audit(state.document.diagnostic, decoded);

    try failures_audit(&state.document, decoded);

    const literal = std.mem.find(u8, decoded, "${") == null;
    const uninterpolated = literal or !options.interpolate;

    if (uninterpolated) try entries_audit(state, decoded);
}

fn text_mutate(prng: *Prng, text: *Text) void {
    assert(text.count <= text_bytes_max);
    assert(text.buffer.len == text_bytes_max);

    const random = prng.random();
    const position = random.uintAtMost(u32, text.count);
    const token = pick(prng, &mutation_tokens);

    switch (random.uintLessThan(u32, 3)) {
        0 => text_insert(text, position, token),
        1 => text_delete(text, position),
        2 => {
            text_delete(text, position);
            text_insert(text, @min(position, text.count), token);
        },
        else => unreachable,
    }
}

fn text_insert(text: *Text, position: u32, token: []const u8) void {
    assert(position <= text.count);
    assert(token.len > 0);

    const length: u32 = @intCast(token.len);
    if (text.buffer.len - text.count < length) return;

    text.resize_assume_capacity(text.count + length);

    const grown = text.slice_mutable();

    std.mem.copyBackwards(u8, grown[position + length ..], grown[position .. grown.len - length]);
    @memcpy(grown[position..][0..length], token);
}

fn text_delete(text: *Text, position: u32) void {
    assert(position <= text.count);
    assert(text.count <= text_bytes_max);

    if (position == text.count) return;

    const bytes = text.slice_mutable();

    std.mem.copyForwards(u8, bytes[position .. bytes.len - 1], bytes[position + 1 ..]);
    text.truncate(text.count - 1);
}

fn statements_audit(state: *State, text: []const u8) !void {
    assert(text.len <= text_bytes_max);
    assert(std.mem.findScalar(u8, text, '\r') == null);

    var scanner: Scanner = .init(text);
    var offset: u32 = 0;

    for (0..text.len + 1) |_| {
        const statement = scanner.next() orelse break;
        const start = @intFromPtr(statement.original.ptr) - @intFromPtr(text.ptr);
        const line: u32 = @intCast(std.mem.countScalar(u8, text[0..offset], '\n') + 1);
        const position = line_column(text, statement_start(text, &statement));

        try testing.expectEqual(@as(usize, offset), start);
        try testing.expectEqual(line, statement.line);
        try testing.expectEqual(position, statement.position);
        try statement_audit(state, text, &statement);

        offset += @intCast(statement.original.len);
    }

    try testing.expectEqual(@as(u32, @intCast(text.len)), offset);
}

fn statement_audit(state: *State, text: []const u8, statement: *const Statement) !void {
    assert(statement.original.len > 0);
    assert(text.len <= text_bytes_max);

    try slice_within(&.{ .inner = statement.body(), .outer = statement.original });

    switch (statement.kind) {
        .binding => {
            try testing.expect(statement.key.len > 0);
            try slice_within(&.{ .inner = statement.key, .outer = statement.body() });

            if (statement.value) |*value| try value_audit(state, text, statement, value);
        },
        .failure, .trivia => {
            try testing.expectEqual(@as(usize, 0), statement.key.len);
            try testing.expectEqual(@as(?Value, null), statement.value);
        },
    }
}

fn value_audit(
    state: *State,
    text: []const u8,
    statement: *const Statement,
    value: *const Value,
) !void {
    assert(statement.kind == .binding);
    assert(text.len <= text_bytes_max);

    try slice_within(&.{ .inner = value.text, .outer = statement.original });

    const unescaped = value.unescape(&state.unescaped);

    try testing.expect(unescaped.len <= value.text.len);

    if (value.quote == .none) {
        try testing.expectEqual(value.text.ptr, unescaped.ptr);
        try testing.expectEqual(value.text.len, text_module.trim_end(value.text).len);

        return;
    }

    const quote: u8 = if (value.quote == .double) '"' else '\'';
    const open: u32 = @intCast(@intFromPtr(value.text.ptr) - @intFromPtr(text.ptr) - 1);
    const close: u32 = open + 1 + @as(u32, @intCast(value.text.len));
    const reference = scanner_module.quote_close_reference(text, open, quote, &state.stack);

    try testing.expectEqual(quote, text[open]);
    try testing.expectEqual(quote, text[close]);
    try testing.expectEqual(@as(?u32, close), reference);
}

fn slice_within(span: *const Span) !void {
    assert(span.outer.len <= text_bytes_max);
    assert(span.inner.len <= span.outer.len);

    const outer_start = @intFromPtr(span.outer.ptr);
    const inner_start = @intFromPtr(span.inner.ptr);

    try testing.expect(inner_start >= outer_start);
    try testing.expect(inner_start + span.inner.len <= outer_start + span.outer.len);
}

fn document_audit(state: *State, source: []const u8, options: *const Options) !bool {
    assert(source.len <= text_bytes_max);
    assert(state.storage.entries.len == entry_count_max);

    const random = state.prng.random();
    const count = random.uintAtMost(u32, environment_table.len);
    const variables = Variables{ .list = environment_table[0..count] };
    const storage = state.storage.storage();
    const parsed = state.document.parse(Variables, storage, &variables, source, options.*);

    parsed catch |err| switch (err) {
        error.EntriesExhausted, error.TextExhausted => return false,
        error.Utf8Invalid => unreachable,
    };

    const entries = state.document.list();

    for (entries, 0..) |*entry, index| {
        try testing.expect(entry.key.len > 0);

        for (entries[0..index]) |*earlier| {
            try testing.expect(!std.mem.eql(u8, earlier.key, entry.key));
        }

        try loaded_audit(&state.document, entry, &variables);
    }

    return true;
}

fn loaded_audit(document: *const Document, entry: *const Entry, variables: *const Variables) !void {
    assert(entry.key.len > 0);
    assert(document.entry_count > 0);

    const loaded = document.loaded(Variables, variables, entry.key);
    const inherited = variables.lookup(entry.key);

    if (document.options.override) {
        try nullable_expect(&.{ .actual = loaded, .expected = entry.value orelse inherited });
    } else {
        try nullable_expect(&.{ .actual = loaded, .expected = inherited orelse entry.value });
    }
}

fn nullable_expect(expectation: *const Expectation) !void {
    if (expectation.expected) |text| assert(text.len <= text_bytes_max * 4);
    if (expectation.actual) |text| assert(text.len <= text_bytes_max * 4);

    const actual = expectation.actual;

    const want = expectation.expected orelse {
        try testing.expectEqual(@as(?[]const u8, null), actual);

        return;
    };

    try testing.expectEqualStrings(want, actual orelse return error.TestUnexpectedResult);
}

fn entries_audit(state: *State, text: []const u8) !void {
    assert(text.len <= text_bytes_max);
    assert(state.document.entry_count <= entry_count_max);

    const entries = state.document.list();
    var scanner: Scanner = .init(text);
    var distinct: u32 = 0;

    for (0..text.len + 1) |_| {
        const statement = scanner.next() orelse break;
        if (statement.kind != .binding) continue;

        const index = entry_index(entries, statement.key) orelse return error.TestUnexpectedResult;

        if (index == distinct) distinct += 1;

        try testing.expect(index < distinct);
        try binding_last_check(state, text, &entries[index]);
    }

    try testing.expectEqual(entries.len, distinct);
}

fn binding_last_check(state: *State, text: []const u8, entry: *const Entry) !void {
    assert(entry.key.len > 0);
    assert(text.len <= text_bytes_max);

    var scanner: Scanner = .init(text);
    var last: ?Statement = null;

    for (0..text.len + 1) |_| {
        const statement = scanner.next() orelse break;
        if (statement.kind != .binding) continue;

        if (std.mem.eql(u8, statement.key, entry.key)) last = statement;
    }

    const binding = last orelse return error.TestUnexpectedResult;

    const value = binding.value orelse {
        return nullable_expect(&.{ .actual = entry.value, .expected = null });
    };

    const expected = value.unescape(&state.unescaped);

    try nullable_expect(&.{ .actual = entry.value, .expected = expected });
}

fn entry_index(entries: []const Entry, key: []const u8) ?u32 {
    assert(entries.len <= entry_count_max);
    assert(key.len > 0);

    for (entries, 0..) |*entry, index| {
        if (!std.mem.eql(u8, entry.key, key)) continue;

        const result: u32 = @intCast(index);

        assert(result < entries.len);

        return result;
    }

    return null;
}

fn model_event(state: *State) !void {
    assert(state.text.buffer.len == text_bytes_max);
    assert(state.model.statements.buffer.len == line_count_max + 1);

    try model_generate(state);

    const source = state.text.slice();
    const options = state.model.options;
    const variables = Variables{ .list = state.model.environment.slice() };
    const storage = state.storage.storage();

    state.document.parse(Variables, storage, &variables, source, options) catch |err| {
        std.debug.print("model document refused: {t}\n\"{f}\"\n", .{
            err,
            std.zig.fmtString(source),
        });

        return err;
    };

    const decoded = try text_module.decode(&state.decoded, source, .{ .diagnostic = null });

    model_verify(state, decoded) catch |err| {
        std.debug.print("model mismatch in \"{f}\"\n", .{std.zig.fmtString(source)});

        model_report(state, decoded);

        return err;
    };

    try failures_audit(&state.document, decoded);
}

fn model_report(state: *const State, text: []const u8) void {
    assert(text.len <= text_bytes_max);
    assert(state.model.statements.count <= line_count_max);

    for (state.model.statements.slice()) |*expected| {
        std.debug.print("expected {t} \"{f}\"\n", .{
            expected.kind,
            std.zig.fmtString(expected.key.slice()),
        });
    }

    var scanner: Scanner = .init(text);

    for (0..text.len + 1) |_| {
        const statement = scanner.next() orelse break;

        std.debug.print("actual {t} \"{f}\" original \"{f}\"\n", .{
            statement.kind,
            std.zig.fmtString(statement.key),
            std.zig.fmtString(statement.original),
        });
    }
}

fn model_generate(state: *State) !void {
    assert(state.text.buffer.len == text_bytes_max);
    assert(environment_table.len > 0);

    const random = state.prng.random();
    const model = &state.model;

    state.text = .empty;
    model.entries = .empty;
    model.environment = .empty;
    model.options = .{ .interpolate = random.boolean(), .override = random.boolean() };
    model.statements = .empty;
    model.trailing = false;

    for (environment_table) |variable| {
        if (random.boolean()) try model.environment.push_slice(&.{variable});
    }

    const line_count = random.uintAtMost(u32, line_count_max);

    for (0..line_count) |index| {
        const shape = std.enums.values(LineShape)[random.uintLessThan(u32, 5)];
        const line_start = state.text.count;

        try line_generate(state, shape);

        const ended = index + 1 < line_count or random.boolean();

        if (ended) try newline_push(state, &line_endings);

        model.trailing = switch (shape) {
            .blank => model.trailing or state.text.count > line_start,
            .binding, .comment, .declaration, .failure => false,
        };
    }
}

fn line_generate(state: *State, shape: LineShape) !void {
    assert(state.text.count < text_bytes_max);
    assert(state.model.statements.count <= line_count_max);

    switch (shape) {
        .binding => try binding_generate(state),
        .blank => try state.text.push_slice(pick(&state.prng, &blank_texts)),
        .comment => {
            try state.text.push_slice(pick(&state.prng, &indents));
            try state.text.push_slice("# a comment = 'x' \"y\" ${A}");
            try statement_expect(&state.model, .trivia, "");
        },
        .declaration => {
            const key = model_keys[state.prng.random().uintLessThan(u32, model_keys.len)];

            try state.text.push_slice(key.spelling);
            try state.text.push_slice(pick(&state.prng, comment_suffixes[0..3]));
            try statement_expect(&state.model, .binding, key.name);
            try entry_expect(&state.model, key.name, null);
        },
        .failure => {
            try state.text.push_slice(pick(&state.prng, &failure_lines));
            try statement_expect(&state.model, .failure, "");
        },
    }
}

fn binding_generate(state: *State) !void {
    assert(state.text.count < text_bytes_max);
    assert(state.model.entries.count <= line_count_max);

    const random = state.prng.random();
    const key = model_keys[random.uintLessThan(u32, model_keys.len)];

    try state.text.push_slice(pick(&state.prng, &indents));
    try state.text.push_slice(pick(&state.prng, &exports));
    try state.text.push_slice(key.spelling);
    try state.text.push_slice(pick(&state.prng, &spaces));
    try state.text.push_slice("=");
    try state.text.push_slice(pick(&state.prng, &spaces));

    state.writer.quote = std.enums.values(Quote)[random.uintLessThan(u32, 3)];

    try value_generate(state);
    try statement_expect(&state.model, .binding, key.name);
    try entry_expect(&state.model, key.name, state.writer.value.slice());
}

fn value_generate(state: *State) !void {
    assert(state.text.count < text_bytes_max);
    assert(state.model.entries.count <= line_count_max);

    const random = state.prng.random();
    const quote = state.writer.quote;

    const quote_text: []const u8 = switch (quote) {
        .double => "\"",
        .none => "",
        .single => "'",
    };

    try state.text.push_slice(quote_text);

    state.writer.reference_count = 0;
    state.writer.start = state.text.count;
    state.writer.value = .empty;

    for (0..random.uintAtMost(u32, codepoint_count_max)) |_| {
        const referenced = random.uintLessThan(u32, 6) == 0;

        if (referenced) {
            if (state.writer.reference_count < reference_count_max) {
                try reference_generate(state);

                continue;
            }
        }

        try character_generate(state);
    }

    try value_finish(state);
    try state.text.push_slice(quote_text);

    const emitted = state.text.count > state.writer.start + quote_text.len;
    const suffix_count: u32 = if (quote != .none) comment_suffixes.len else if (emitted) 3 else 2;

    try state.text.push_slice(pick(&state.prng, comment_suffixes[0..suffix_count]));
}

fn character_generate(state: *State) !void {
    assert(state.writer.value.count() <= short_bytes_max);
    assert(state.text.count >= state.writer.start);

    switch (state.writer.quote) {
        .double => {
            const character = pick(&state.prng, &double_alphabet);

            try double_encode(state, character);
            try state.writer.value.push(character);
        },
        .none => {
            const spaced = state.prng.random().uintLessThan(u32, 5) == 0;

            if (spaced) {
                if (state.text.count > state.writer.start) {
                    if (!source_ends_with_space(state)) try bare_push(state, " ");
                }
            }

            const character = pick(&state.prng, &bare_alphabet);
            const hashed = std.mem.eql(u8, character, "#");

            if (hashed) {
                if (source_ends_with_space(state)) return bare_push(state, "h");
            }

            try bare_push(state, character);
        },
        .single => {
            const character = pick(&state.prng, &single_alphabet);

            try single_encode(state, character);
            try state.writer.value.push(character);
        },
    }
}

fn source_ends_with_space(state: *const State) bool {
    assert(state.text.count <= text_bytes_max);
    assert(state.text.count >= state.writer.start);

    if (state.text.count == state.writer.start) return false;
    return state.text.slice()[state.text.count - 1] == ' ';
}

fn bare_push(state: *State, bytes: []const u8) !void {
    assert(bytes.len > 0);
    assert(state.writer.quote == .none);

    try state.text.push_slice(bytes);
    try state.writer.value.push(bytes);
}

fn double_encode(state: *State, character: []const u8) !void {
    assert(character.len > 0);
    assert(state.writer.quote == .double);

    const random = state.prng.random();

    switch (character[0]) {
        '"' => try state.text.push_slice("\\\""),
        '\\' => try state.text.push_slice("\\\\"),
        '\r' => try state.text.push_slice("\\r"),
        '\n' => try newline_push(state, &.{ "\\n", "\n", "\r\n", "\r" }),
        '\t' => try state.text.push_slice(if (random.boolean()) "\\t" else "\t"),
        '\'' => try state.text.push_slice(if (random.boolean()) "\\'" else "'"),
        else => try state.text.push_slice(character),
    }
}

fn single_encode(state: *State, character: []const u8) !void {
    assert(character.len > 0);
    assert(state.writer.quote == .single);

    switch (character[0]) {
        '\'' => try state.text.push_slice("\\'"),
        '\\' => try state.text.push_slice("\\\\"),
        '\n' => try newline_push(state, &.{ "\n", "\r\n", "\r" }),
        else => try state.text.push_slice(character),
    }
}

fn newline_push(state: *State, encodings: []const []const u8) !void {
    assert(encodings.len > 0);
    assert(state.text.count < text_bytes_max);

    const encoding = pick(&state.prng, encodings);
    const carriage_last = std.mem.endsWith(u8, state.text.slice(), "\r");

    if (carriage_last) {
        if (encoding[0] == '\n') return state.text.push_slice("\r\n");
    }

    try state.text.push_slice(encoding);
}

fn value_finish(state: *State) !void {
    assert(state.writer.value.count() <= short_bytes_max);
    assert(state.text.count >= state.writer.start);

    if (state.text.count == state.writer.start) return;

    const last = state.text.slice()[state.text.count - 1];

    const closing_escaped = switch (state.writer.quote) {
        .double, .single => last == '\\',
        .none => last == ' ',
    };

    if (!closing_escaped) return;

    try state.text.push_slice("z");
    try state.writer.value.push("z");
}

fn reference_generate(state: *State) !void {
    assert(state.writer.reference_count < reference_count_max);
    assert(state.writer.value.count() <= short_bytes_max);

    const random = state.prng.random();
    const name = pick(&state.prng, &reference_names);
    const defaulted = random.boolean();
    var default: Short = .empty;

    state.writer.reference_count += 1;

    if (defaulted) {
        const default_length = random.uintAtMost(u32, 3);

        for (0..default_length) |_| try default.push(pick(&state.prng, &default_alphabet));
    }

    const fallback: ?[]const u8 = if (defaulted) default.slice() else null;
    const resolved = model_lookup(&state.model, name, fallback);
    if (resolved.len + state.writer.value.count() + 64 > short_bytes_max) return;

    var spelled: Short = .empty;

    if (defaulted) {
        try spelled.print("${{{s}:-{s}}}", .{ name, default.slice() });
    } else {
        try spelled.print("${{{s}}}", .{name});
    }

    try state.text.push_slice(spelled.slice());

    const expanded = if (state.model.options.interpolate) resolved else spelled.slice();

    try state.writer.value.push(expanded);
}

fn model_lookup(model: *const Model, name: []const u8, fallback: ?[]const u8) []const u8 {
    assert(name.len > 0);
    assert(model.entries.count <= line_count_max);
    if (fallback) |text| assert(text.len <= short_bytes_max);

    const declared = model_entry_find(model, name);
    const environment = Variables{ .list = model.environment.slice() };
    const inherited = environment.lookup(name);

    if (model.options.override) {
        if (declared) |entry| return if (entry.value) |*found| found.slice() else "";
        if (inherited) |found| return found;
    } else {
        if (inherited) |found| return found;
        if (declared) |entry| return if (entry.value) |*found| found.slice() else "";
    }

    return fallback orelse "";
}

fn model_entry_find(model: *const Model, key: []const u8) ?*const ModelEntry {
    assert(key.len > 0);
    assert(model.entries.count <= line_count_max);

    for (model.entries.slice()) |*entry| {
        if (std.mem.eql(u8, entry.key.slice(), key)) return entry;
    }

    return null;
}

fn statement_expect(model: *Model, kind: Kind, key: []const u8) !void {
    assert(model.statements.count <= line_count_max);
    if (kind == .binding) assert(key.len > 0);

    const slot = try model.statements.push_slot();

    slot.* = .{ .key = .empty, .kind = kind };

    try slot.key.push(key);
}

fn entry_expect(model: *Model, key: []const u8, value: ?[]const u8) !void {
    assert(key.len > 0);
    assert(model.entries.count <= line_count_max);
    if (value) |text| assert(text.len <= short_bytes_max);

    var stored: ?Short = null;

    if (value) |text| {
        var copy: Short = .empty;

        try copy.push(text);

        stored = copy;
    }

    for (model.entries.slice_mutable()) |*entry| {
        if (!std.mem.eql(u8, entry.key.slice(), key)) continue;

        entry.value = stored;

        return;
    }

    const slot = try model.entries.push_slot();

    slot.* = .{ .key = .empty, .value = stored };

    try slot.key.push(key);
}

fn model_verify(state: *State, text: []const u8) !void {
    assert(text.len <= text_bytes_max);
    assert(state.model.statements.count <= line_count_max);

    try statements_audit(state, text);

    var scanner: Scanner = .init(text);

    for (state.model.statements.slice()) |*expected| {
        const statement = scanner.next() orelse return error.TestUnexpectedResult;

        try testing.expectEqual(expected.kind, statement.kind);
        try testing.expectEqualStrings(expected.key.slice(), statement.key);
    }

    if (state.model.trailing) {
        const statement = scanner.next() orelse return error.TestUnexpectedResult;

        try testing.expectEqual(Kind.trivia, statement.kind);
    }

    const extra = scanner.next();

    try testing.expectEqual(@as(?Statement, null), extra);

    const entries = state.document.list();

    try testing.expectEqual(state.model.entries.count, @as(u32, @intCast(entries.len)));

    for (state.model.entries.slice(), entries) |*expected, *entry| {
        try testing.expectEqualStrings(expected.key.slice(), entry.key);

        const value: ?[]const u8 = if (expected.value) |*found| found.slice() else null;

        try nullable_expect(&.{ .actual = entry.value, .expected = value });
    }
}

fn statement_start(text: []const u8, statement: *const Statement) u32 {
    assert(statement.original.len > 0);
    assert(text.len <= text_bytes_max);

    const body_start: u32 = @intCast(@intFromPtr(statement.body().ptr) - @intFromPtr(text.ptr));
    if (statement.kind != .binding) return export_end(text, body_start);

    const key_start: u32 = @intCast(@intFromPtr(statement.key.ptr) - @intFromPtr(text.ptr));
    const quoted = key_start > body_start and text[key_start - 1] == '\'';
    const result = if (quoted) key_start - 1 else key_start;

    assert(result >= body_start);
    assert(result < text.len);

    return result;
}

fn export_end(text: []const u8, start: u32) u32 {
    assert(start <= text.len);
    assert(text.len <= text_bytes_max);

    const keyword = "export";
    const keyword_length: u32 = keyword.len;

    if (!std.mem.startsWith(u8, text[start..], keyword)) return start;

    const after = start + keyword_length;
    var index = after;

    for (0..text.len) |_| {
        if (index == text.len) break;
        if (text[index] == '\n') break;

        const length = text_module.whitespace_length(text, index);
        if (length == 0) break;

        index += length;
    }

    if (index == after) return start;
    return index;
}

fn line_column(text: []const u8, offset: u32) Position {
    assert(offset <= text.len);
    assert(std.mem.findScalar(u8, text[0..offset], '\r') == null);

    const before = text[0..offset];
    const line_start = if (std.mem.findScalarLast(u8, before, '\n')) |index| index + 1 else 0;
    const lines = std.mem.countScalar(u8, before, '\n');

    var codepoints = std.unicode.Utf8View.initUnchecked(before[line_start..]).iterator();
    var columns: u32 = 0;

    for (0..before.len - line_start) |_| {
        _ = codepoints.nextCodepointSlice() orelse break;

        columns += 1;
    }

    const result = Position{ .column = columns + 1, .line = @intCast(lines + 1) };

    assert(result.column <= offset - line_start + 1);

    return result;
}

fn utf8_valid_prefix(source: []const u8) u32 {
    assert(source.len <= text_bytes_max);
    assert(source.len < std.math.maxInt(u32));

    var valid: u32 = 0;

    for (1..source.len + 1) |end| {
        if (end - valid > 4) break;

        if (std.unicode.utf8ValidateSlice(source[valid..end])) valid = @intCast(end);
    }

    assert(valid <= source.len);

    return valid;
}

fn invalid_audit(state: *State, source: []const u8, diagnostic: Position) !void {
    assert(source.len <= text_bytes_max);
    assert(!std.unicode.utf8ValidateSlice(source));
    assert(diagnostic.line > 0);

    const valid = utf8_valid_prefix(source);

    try testing.expect(valid < source.len);

    const decode_options = text_module.DecodeOptions{ .diagnostic = null };
    const prefix = try text_module.decode(&state.unescaped, source[0..valid], decode_options);

    try testing.expectEqual(line_column(prefix, @intCast(prefix.len)), diagnostic);
}

fn diagnostic_audit(diagnostic: Position, text: []const u8) !void {
    assert(text.len <= text_bytes_max);
    assert(diagnostic.line > 0);

    var scanner: Scanner = .init(text);

    for (0..text.len + 1) |_| {
        const statement = scanner.next() orelse break;
        if (statement.kind != .binding) continue;
        if (std.meta.eql(statement.position, diagnostic)) return;
    }

    return error.TestUnexpectedResult;
}

fn failures_audit(document: *const Document, text: []const u8) !void {
    assert(text.len <= text_bytes_max);
    assert(document.failure_count <= text.len);

    var scanner: Scanner = .init(text);
    var failures = document.failures();
    var count: u32 = 0;

    for (0..text.len + 1) |_| {
        const statement = scanner.next() orelse break;
        if (statement.kind != .failure) continue;

        count += 1;

        if (count > document.failure_positions.len) continue;

        const position = failures.next() orelse return error.TestUnexpectedResult;

        try testing.expectEqual(statement.position, position);
    }

    const after = failures.next();

    try testing.expectEqual(count, document.failure_count);
    try testing.expectEqual(@as(?Position, null), after);
}

fn capacity_event(state: *State) !void {
    assert(state.text.buffer.len == text_bytes_max);
    assert(state.dense_rule.entries.len == @divFloor(dense_bytes_max, 2) + 1);

    const random = state.prng.random();

    try dense_generate(state);

    for (0..random.uintAtMost(u32, 2)) |_| text_mutate(&state.prng, &state.text);

    const source = state.text.slice();
    const literal = std.mem.find(u8, source, "${") == null;
    const interpolate = if (literal) random.boolean() else false;
    const options = Options{ .interpolate = interpolate, .override = random.boolean() };
    const storage = dense_storage(&state.dense_rule, @intCast(source.len));

    state.document.parse(void, storage, &{}, source, options) catch |err| switch (err) {
        error.EntriesExhausted, error.TextExhausted => {
            std.debug.print("capacity rule refused: {t}\n\"{f}\"\n", .{
                err,
                std.zig.fmtString(source),
            });

            return err;
        },
        error.Utf8Invalid => return invalid_audit(state, source, state.document.diagnostic),
    };

    try testing.expect(state.document.failure_count <= storage.failures.len);
    try statements_audit(state, state.document.source);
    try failures_audit(&state.document, state.document.source);

    witness_update(state, @intCast(source.len));

    try entries_shrunk_audit(state, source, &options);
    try text_shrunk_audit(state, source, &options);
}

fn dense_storage(dense: *DenseStorage, length: u32) document_module.Storage {
    assert(length <= dense_bytes_max);
    assert(dense.text.len == 2 * dense_bytes_max);

    const bound = @divFloor(length, 2) + 1;

    return .{
        .entries = dense.entries[0..bound],
        .failures = dense.failures[0..bound],
        .text = dense.text[0 .. 2 * length],
    };
}

fn witness_update(state: *State, length: u32) void {
    assert(length <= dense_bytes_max);
    assert(state.document.entry_count <= @divFloor(length, 2) + 1);

    const bound = @divFloor(length, 2) + 1;
    const document = &state.document;

    if (document.entry_count == bound) state.witness.entries = true;
    if (document.failure_count == bound) state.witness.failures = true;
    if (length < 16) return;

    if (document.text_used + 8 >= 2 * length) state.witness.text = true;
}

fn entries_shrunk_audit(state: *State, source: []const u8, options: *const Options) !void {
    assert(source.len <= dense_bytes_max);
    assert(state.document.entry_count <= state.dense_rule.entries.len);

    const entries = state.document.list();
    if (entries.len == 0) return;

    const length: u32 = @intCast(source.len);
    const count = state.prng.random().intRangeAtMost(u32, 1, @intCast(entries.len));

    const storage = document_module.Storage{
        .entries = state.dense_shrunk.entries[0..count],
        .failures = state.dense_shrunk.failures[0..0],
        .text = state.dense_shrunk.text[0 .. 2 * length],
    };

    const parsed = state.shrunk.parse(void, storage, &{}, source, options.*);

    if (count == entries.len) {
        try parsed;
        try entries_expect(&.{ .actual = state.shrunk.list(), .expected = entries });
        try testing.expectEqual(state.document.failure_count, state.shrunk.failure_count);

        return;
    }

    try testing.expectError(error.EntriesExhausted, parsed);

    const overflow = entries[count].key;

    const position = binding_position(&state.document, overflow) orelse {
        return error.TestUnexpectedResult;
    };

    try testing.expectEqual(position, state.shrunk.diagnostic);
}

fn text_shrunk_audit(state: *State, source: []const u8, options: *const Options) !void {
    assert(source.len <= dense_bytes_max);
    assert(state.document.text_used <= 2 * source.len);

    const length: u32 = @intCast(source.len);
    const bound = @divFloor(length, 2) + 1;
    const text_count = state.prng.random().uintAtMost(u32, 2 * length);

    const storage = document_module.Storage{
        .entries = state.dense_shrunk.entries[0..bound],
        .failures = state.dense_shrunk.failures[0..bound],
        .text = state.dense_shrunk.text[0..text_count],
    };

    const parsed = state.shrunk.parse(void, storage, &{}, source, options.*);
    const exhausted = text_exhaustion(state, source, text_count);

    const position = exhausted orelse {
        try parsed;
        try entries_expect(&.{ .actual = state.shrunk.list(), .expected = state.document.list() });

        return;
    };

    try testing.expectError(error.TextExhausted, parsed);
    try testing.expectEqual(position, state.shrunk.diagnostic);
}

fn text_exhaustion(state: *State, source: []const u8, text_count: u32) ?Position {
    assert(source.len <= dense_bytes_max);
    assert(text_count <= 2 * source.len);

    const decoded = state.document.source;
    var used: u32 = 0;

    if (std.mem.findScalar(u8, source, '\r')) |carriage| {
        if (text_count < source.len) return line_column(source, @intCast(carriage));

        used = @intCast(decoded.len);
    }

    var scanner: Scanner = .init(decoded);

    for (0..decoded.len + 1) |_| {
        const statement = scanner.next() orelse break;
        if (statement.kind != .binding) continue;

        const value = statement.value orelse continue;
        if (!value.escapes_present()) continue;
        if (text_count - used < value.text.len) return statement.position;

        used += @intCast(value.unescape(&state.unescaped).len);
    }

    return null;
}

fn binding_position(document: *const Document, key: []const u8) ?Position {
    assert(document.source.len <= text_bytes_max);
    assert(key.len > 0);

    const text = document.source;

    var scanner: Scanner = .init(text);

    for (0..text.len + 1) |_| {
        const statement = scanner.next() orelse break;
        if (statement.kind != .binding) continue;
        if (std.mem.eql(u8, statement.key, key)) return statement.position;
    }

    return null;
}

fn entries_expect(expectation: *const EntriesExpectation) !void {
    assert(expectation.actual.len <= entry_count_max);
    assert(expectation.expected.len <= entry_count_max);

    try testing.expectEqual(expectation.expected.len, expectation.actual.len);

    for (expectation.expected, expectation.actual) |*want, *entry| {
        try testing.expectEqualStrings(want.key, entry.key);
        try nullable_expect(&.{ .actual = entry.value, .expected = want.value });
    }
}

fn dense_generate(state: *State) !void {
    assert(state.text.buffer.len == text_bytes_max);
    assert(dense_keys.len >= dense_key_count_max);

    const random = state.prng.random();
    const shape = std.enums.values(DenseShape)[random.uintLessThan(u32, 4)];

    state.text = .empty;

    switch (shape) {
        .entries => try dense_entries(state),
        .failures => try dense_failures(state),
        .mixed => try dense_mixed(state),
        .text => try dense_text(state),
    }

    assert(state.text.count <= dense_fill_max);
}

fn dense_entries(state: *State) !void {
    assert(state.text.count == 0);
    assert(dense_keys.len >= dense_key_count_max);

    const random = state.prng.random();
    const count = random.intRangeAtMost(u32, 1, dense_key_count_max);
    const separator = pick(&state.prng, &dense_separators);

    var keys = dense_keys.*;

    random.shuffle(u8, &keys);

    for (keys[0..count], 0..) |*key, index| {
        if (index > 0) try state.text.push_slice(separator);

        try state.text.push_slice(key[0..1]);
    }

    if (random.boolean()) try state.text.push_slice(separator);
}

fn dense_failures(state: *State) !void {
    assert(state.text.count == 0);
    assert(dense_failure_count_max > 0);

    const random = state.prng.random();
    const count = random.intRangeAtMost(u32, 1, dense_failure_count_max);
    const separator = pick(&state.prng, &dense_separators);

    for (0..count) |index| {
        if (index > 0) try state.text.push_slice(separator);

        try state.text.push_slice("=");
    }

    if (random.boolean()) try state.text.push_slice(separator);
}

fn dense_mixed(state: *State) !void {
    assert(state.text.count == 0);
    assert(dense_units.len > 0);

    const random = state.prng.random();

    for (0..random.uintAtMost(u32, dense_unit_count_max)) |_| {
        if (state.text.count + 16 > dense_fill_max) break;

        const keyed = random.uintLessThan(u32, 3) == 0;

        if (keyed) {
            const index = random.uintLessThan(u32, dense_keys.len);

            try state.text.push_slice(dense_keys[index..][0..1]);

            continue;
        }

        try state.text.push_slice(pick(&state.prng, &dense_units));
    }
}

fn dense_text(state: *State) !void {
    assert(state.text.count == 0);
    assert(dense_quoted_bytes_max > 0);

    const random = state.prng.random();
    const quote: []const u8 = if (random.boolean()) "\"" else "'";
    const length = random.intRangeAtMost(u32, 1, dense_quoted_bytes_max);
    const escape_index = random.uintLessThan(u32, length);
    const escapes_extra = random.boolean();

    try state.text.push_slice("K=");
    try state.text.push_slice(quote);

    for (0..length) |index| {
        const extra = random.uintLessThan(u32, 32) == 0;
        const escaped = if (index == escape_index) true else escapes_extra and extra;

        try state.text.push_slice(if (escaped) "\\\\" else "x");
    }

    try state.text.push_slice(quote);
    try state.text.push_slice(pick(&state.prng, &dense_endings));
}
