const std = @import("std");

const text_module = @import("text.zig");

const assert = std.debug.assert;

const Position = text_module.Position;

const source_bytes_max = text_module.source_bytes_max;

pub const Statement = struct {
    body_offset: u32,
    key: []const u8,
    kind: Kind,
    line: u32,
    original: []const u8,
    position: Position,
    value: ?Value,

    pub const Kind = enum {
        binding,
        failure,
        trivia,
    };

    pub const Quote = enum {
        double,
        none,
        single,
    };

    pub const Value = struct {
        quote: Quote,
        text: []const u8,

        pub fn escapes_present(value: *const Value) bool {
            assert(value.text.len <= source_bytes_max);
            assert(value.text.len < std.math.maxInt(u32));

            if (value.quote == .none) return false;

            const result = std.mem.findScalar(u8, value.text, '\\') != null;

            if (result) assert(value.text.len > 0);

            return result;
        }

        pub fn unescape(value: *const Value, target: []u8) []const u8 {
            assert(value.text.len <= source_bytes_max);
            assert(target.len < std.math.maxInt(u32));

            if (!value.escapes_present()) return value.text;

            assert(target.len >= value.text.len);
            assert(text_module.buffers_disjoint(&.{ .source = value.text, .target = target }));

            var length: u32 = 0;
            var index: u32 = 0;

            for (0..value.text.len) |_| {
                if (index == value.text.len) break;

                if (escape_decoded(value.quote, value.text[index..])) |decoded| {
                    target[length] = decoded;
                    index += 2;
                } else {
                    target[length] = value.text[index];
                    index += 1;
                }

                length += 1;
            }

            const result = target[0..length];

            assert(index == value.text.len);
            assert(result.len <= value.text.len);

            return result;
        }
    };

    pub fn body(statement: *const Statement) []const u8 {
        assert(statement.original.len > 0);
        assert(statement.body_offset <= statement.original.len);

        const result = statement.original[statement.body_offset..];

        if (statement.kind == .binding) assert(result.len >= statement.key.len);

        return result;
    }
};

const Binding = struct {
    key: []const u8,
    value: ?Statement.Value,
};

const KeyParsed = union(enum) {
    comment,
    failure,
    found: []const u8,
};

const Parsed = union(enum) {
    binding: Binding,
    failure,
    trivia,
};

const ValueParsed = union(enum) {
    absent,
    failure,
    found: Statement.Value,
};

pub const Scanner = struct {
    line: u32,
    offset: u32,
    text: []const u8,

    pub fn init(text: []const u8) Scanner {
        assert(text.len <= source_bytes_max);
        assert(std.mem.findScalar(u8, text, '\r') == null);
        assert(std.unicode.utf8ValidateSlice(text));

        return .{ .line = 1, .offset = 0, .text = text };
    }

    pub fn next(scanner: *Scanner) ?Statement {
        assert(scanner.offset <= scanner.text.len);
        assert(scanner.line > 0);

        if (scanner.offset == scanner.text.len) return null;

        const mark = scanner.offset;

        if (mark > 0) assert(scanner.text[mark - 1] == '\n');

        scanner.offset = whitespace_end(scanner.text, mark);

        const body_offset = scanner.offset - mark;
        const at_end = scanner.offset == scanner.text.len;

        if (!at_end) scanner.export_skip();

        const position = scanner.position_from(mark);
        const parsed: Parsed = if (at_end) .trivia else scanner.binding_parse();

        if (parsed == .failure) scanner.offset = line_rest_end(scanner.text, scanner.offset);

        const original = scanner.text[mark..scanner.offset];

        var result = Statement{
            .body_offset = body_offset,
            .key = "",
            .kind = .trivia,
            .line = scanner.line,
            .original = original,
            .position = position,
            .value = null,
        };

        switch (parsed) {
            .binding => |binding| {
                result.key = binding.key;
                result.kind = .binding;
                result.value = binding.value;
            },
            .failure => result.kind = .failure,
            .trivia => {},
        }

        scanner.line += @intCast(std.mem.countScalar(u8, original, '\n'));

        assert(original.len > 0);
        assert(scanner.offset > mark);

        return result;
    }

    fn position_from(scanner: *const Scanner, mark: u32) Position {
        assert(mark <= scanner.offset);
        assert(scanner.offset <= scanner.text.len);

        const relative = text_module.position_of(scanner.text[mark..], scanner.offset - mark);

        const result = Position{
            .column = relative.column,
            .line = scanner.line + relative.line - 1,
        };

        assert(result.line >= scanner.line);

        return result;
    }

    fn binding_parse(scanner: *Scanner) Parsed {
        assert(scanner.offset <= scanner.text.len);
        assert(space_end(scanner.text, scanner.offset) == scanner.offset);

        const key_parsed = scanner.key_parse();
        if (key_parsed == .failure) return .failure;

        scanner.offset = space_end(scanner.text, scanner.offset);

        const value_parsed = scanner.assignment_parse();
        if (value_parsed == .failure) return .failure;

        scanner.comment_skip();

        if (!scanner.line_end()) return .failure;

        const key = switch (key_parsed) {
            .comment => return .trivia,
            .failure => unreachable,
            .found => |found| found,
        };

        const value: ?Statement.Value = switch (value_parsed) {
            .absent => null,
            .failure => unreachable,
            .found => |found| found,
        };

        assert(key.len > 0);

        return .{ .binding = .{ .key = key, .value = value } };
    }

    fn export_skip(scanner: *Scanner) void {
        assert(scanner.offset < scanner.text.len);
        assert(scanner.text.len <= source_bytes_max);

        const keyword = "export";
        const keyword_length: u32 = keyword.len;

        if (!std.mem.startsWith(u8, scanner.text[scanner.offset..], keyword)) return;

        const after = scanner.offset + keyword_length;
        const end = space_end(scanner.text, after);
        if (end == after) return;

        scanner.offset = end;
    }

    fn key_parse(scanner: *Scanner) KeyParsed {
        assert(scanner.offset <= scanner.text.len);
        assert(scanner.text.len <= source_bytes_max);

        if (scanner.offset == scanner.text.len) return .failure;

        return switch (scanner.text[scanner.offset]) {
            '#' => .comment,
            '\'' => scanner.key_quoted(),
            else => scanner.key_bare(),
        };
    }

    fn key_quoted(scanner: *Scanner) KeyParsed {
        assert(scanner.offset < scanner.text.len);
        assert(scanner.text[scanner.offset] == '\'');

        const start = scanner.offset + 1;
        const close = std.mem.findScalarPos(u8, scanner.text, start, '\'') orelse return .failure;
        if (close == start) return .failure;

        scanner.offset = @intCast(close + 1);

        return .{ .found = scanner.text[start..close] };
    }

    fn key_bare(scanner: *Scanner) KeyParsed {
        assert(scanner.offset < scanner.text.len);
        assert(scanner.text[scanner.offset] != '#');

        const start = scanner.offset;
        const end = key_bare_end(scanner.text, start);
        if (end == start) return .failure;

        scanner.offset = end;

        return .{ .found = scanner.text[start..end] };
    }

    fn assignment_parse(scanner: *Scanner) ValueParsed {
        assert(scanner.offset <= scanner.text.len);
        assert(scanner.text.len <= source_bytes_max);

        if (scanner.offset == scanner.text.len) return .absent;
        if (scanner.text[scanner.offset] != '=') return .absent;

        scanner.offset = space_end(scanner.text, scanner.offset + 1);

        return scanner.value_parse();
    }

    fn value_parse(scanner: *Scanner) ValueParsed {
        assert(scanner.offset <= scanner.text.len);
        assert(scanner.offset > 0);

        const empty = Statement.Value{
            .quote = .none,
            .text = scanner.text[scanner.offset..scanner.offset],
        };

        if (scanner.offset == scanner.text.len) return .{ .found = empty };

        return switch (scanner.text[scanner.offset]) {
            '"' => scanner.value_quoted(.double),
            '\'' => scanner.value_quoted(.single),
            '\n' => .{ .found = empty },
            else => .{ .found = scanner.value_bare() },
        };
    }

    fn value_quoted(scanner: *Scanner, quote: Statement.Quote) ValueParsed {
        assert(quote != .none);
        assert(scanner.offset < scanner.text.len);

        const open = scanner.offset;
        const close = quote_close(scanner.text, open, quote_byte(quote)) orelse return .failure;

        scanner.offset = close + 1;

        return .{ .found = .{ .quote = quote, .text = scanner.text[open + 1 .. close] } };
    }

    fn value_bare(scanner: *Scanner) Statement.Value {
        assert(scanner.offset < scanner.text.len);
        assert(scanner.text[scanner.offset] != '\n');

        const start = scanner.offset;
        const end = line_end_offset(scanner.text, start);
        const part = scanner.text[start..end];

        scanner.offset = end;

        const kept = part[0..comment_cut(part)];
        const result = Statement.Value{ .quote = .none, .text = text_module.trim_end(kept) };

        assert(result.text.len <= part.len);

        return result;
    }

    fn comment_skip(scanner: *Scanner) void {
        assert(scanner.offset <= scanner.text.len);
        assert(scanner.text.len <= source_bytes_max);

        const offset = space_end(scanner.text, scanner.offset);
        if (offset == scanner.text.len) return;
        if (scanner.text[offset] != '#') return;

        scanner.offset = line_end_offset(scanner.text, offset);
    }

    fn line_end(scanner: *Scanner) bool {
        assert(scanner.offset <= scanner.text.len);
        assert(scanner.text.len <= source_bytes_max);

        const offset = space_end(scanner.text, scanner.offset);

        if (offset == scanner.text.len) {
            scanner.offset = offset;

            return true;
        }

        if (scanner.text[offset] != '\n') return false;

        scanner.offset = offset + 1;

        return true;
    }
};

pub fn quote_close(text: []const u8, open: u32, quote: u8) ?u32 {
    assert(open < text.len);
    assert(text[open] == quote);

    var pair_last: ?u32 = null;
    var cursor: u32 = open + 1;

    for (0..text.len) |_| {
        const found = std.mem.findScalarPos(u8, text, cursor, quote) orelse break;
        const index: u32 = @intCast(found);
        if (text[index - 1] != '\\') return index;

        pair_last = index;
        cursor = index + 1;
    }

    if (pair_last) |index| assert(text[index - 1] == '\\');

    return pair_last;
}

fn escape_decoded(quote: Statement.Quote, rest: []const u8) ?u8 {
    assert(quote != .none);
    assert(rest.len > 0);

    if (rest[0] != '\\') return null;
    if (rest.len == 1) return null;

    const result: ?u8 = switch (quote) {
        .double => switch (rest[1]) {
            '"', '\'', '\\' => rest[1],
            'a' => 0x07,
            'b' => 0x08,
            'f' => 0x0c,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'v' => 0x0b,
            else => null,
        },
        .none => unreachable,
        .single => switch (rest[1]) {
            '\'', '\\' => rest[1],
            else => null,
        },
    };

    return result;
}

fn quote_byte(quote: Statement.Quote) u8 {
    assert(quote != .none);

    const result: u8 = switch (quote) {
        .double => '"',
        .none => unreachable,
        .single => '\'',
    };

    assert(result < 0x80);

    return result;
}

fn whitespace_end(text: []const u8, start: u32) u32 {
    assert(start <= text.len);
    assert(text.len <= source_bytes_max);

    var index = start;

    for (0..text.len) |_| {
        if (index == text.len) break;

        const length = text_module.whitespace_length(text, index);
        if (length == 0) break;

        index += length;
    }

    assert(index >= start);

    return index;
}

fn space_end(text: []const u8, start: u32) u32 {
    assert(start <= text.len);
    assert(text.len <= source_bytes_max);

    var index = start;

    for (0..text.len) |_| {
        if (index == text.len) break;
        if (text[index] == '\n') break;

        const length = text_module.whitespace_length(text, index);
        if (length == 0) break;

        index += length;
    }

    assert(index >= start);

    return index;
}

fn key_bare_end(text: []const u8, start: u32) u32 {
    assert(start < text.len);
    assert(text.len <= source_bytes_max);

    var index = start;

    for (text[start..]) |byte| {
        if (byte == '=') break;
        if (byte == '#') break;
        if (text_module.whitespace_length(text, index) > 0) break;

        index += 1;
    }

    assert(index >= start);
    assert(index <= text.len);

    return index;
}

fn line_end_offset(text: []const u8, start: u32) u32 {
    assert(start <= text.len);
    assert(text.len <= source_bytes_max);

    const result: u32 = @intCast(std.mem.findScalarPos(u8, text, start, '\n') orelse text.len);

    assert(result >= start);

    return result;
}

fn line_rest_end(text: []const u8, start: u32) u32 {
    assert(start <= text.len);
    assert(text.len <= source_bytes_max);

    const end = line_end_offset(text, start);
    const result = if (end == text.len) end else end + 1;

    assert(result >= start);
    if (start < text.len) assert(result > start);

    return result;
}

fn comment_cut(part: []const u8) u32 {
    assert(part.len <= source_bytes_max);
    assert(std.mem.findScalar(u8, part, '\n') == null);

    var run_start: ?u32 = null;
    var index: u32 = 0;
    var result: u32 = @intCast(part.len);

    for (0..part.len) |_| {
        if (index == part.len) break;

        const length = text_module.whitespace_length(part, index);

        if (length > 0) {
            if (run_start == null) run_start = index;

            index += length;

            continue;
        }

        if (part[index] == '#') {
            if (run_start) |start| {
                result = start;

                break;
            }
        }

        run_start = null;
        index += 1;
    }

    assert(result <= part.len);

    return result;
}

pub const ReferenceFrame = struct {
    option: u8,
    position: u32,
};

pub fn quote_close_reference(text: []const u8, open: u32, quote: u8, stack: []ReferenceFrame) ?u32 {
    assert(open < text.len);
    assert(stack.len > text.len);
    assert(text[open] == quote);

    var depth: u32 = 1;

    stack[0] = .{ .option = 0, .position = open + 1 };

    for (0..8 * text.len + 16) |_| {
        if (depth == 0) return null;

        const frame = &stack[depth - 1];
        const position = frame.position;
        const option = frame.option;

        frame.option += 1;

        switch (option) {
            0 => if (reference_pair_at(text, position, quote)) {
                stack[depth] = .{ .option = 0, .position = position + 2 };
                depth += 1;
            },
            1 => if (reference_other_at(text, position, quote)) {
                stack[depth] = .{ .option = 0, .position = position + 1 };
                depth += 1;
            },
            2 => if (reference_quote_at(text, position, quote)) return position,
            else => depth -= 1,
        }
    }

    unreachable;
}

fn reference_pair_at(text: []const u8, position: u32, quote: u8) bool {
    assert(position <= text.len);
    assert(quote < 0x80);

    if (position + 1 >= text.len) return false;
    if (text[position] != '\\') return false;
    return text[position + 1] == quote;
}

fn reference_other_at(text: []const u8, position: u32, quote: u8) bool {
    assert(position <= text.len);
    assert(quote < 0x80);

    if (position == text.len) return false;
    return text[position] != quote;
}

fn reference_quote_at(text: []const u8, position: u32, quote: u8) bool {
    assert(position <= text.len);
    assert(quote < 0x80);

    if (position == text.len) return false;
    return text[position] == quote;
}

const testing = std.testing;

test "quote_close agrees with a backtracking run of python-dotenv's quoted-value regex" {
    const alphabet = "a\\\"'";
    const alphabet_length: u32 = alphabet.len;
    var buffer: [10]u8 = undefined;
    var stack: [buffer.len + 1]ReferenceFrame = undefined;

    for (1..buffer.len + 1) |length| {
        var combinations: u32 = 1;

        for (1..length) |_| combinations *= alphabet_length;

        for (0..combinations) |combination| {
            var rest: u32 = @intCast(combination);

            for (1..length) |position| {
                buffer[position] = alphabet[rest % alphabet_length];
                rest = @divFloor(rest, alphabet_length);
            }

            for ([_]u8{ '"', '\'' }) |quote| {
                buffer[0] = quote;

                const text = buffer[0..length];
                const expected = quote_close_reference(text, 0, quote, &stack);

                try testing.expectEqual(expected, quote_close(text, 0, quote));
            }
        }
    }
}

const Expected = struct {
    key: ?[]const u8,
    line: u32,
    original: []const u8,
    value: ?[]const u8,
};

fn test_scan(text: []const u8, expected: []const Expected) !void {
    assert(text.len <= 4096);
    assert(expected.len <= 64);

    var scanner: Scanner = .init(text);
    var buffer: [4096]u8 = undefined;

    for (expected) |want| {
        const statement = scanner.next() orelse return error.TestUnexpectedResult;

        try testing.expectEqualStrings(want.original, statement.original);
        try testing.expectEqual(want.line, statement.line);

        if (want.key) |key| {
            try testing.expectEqual(Statement.Kind.binding, statement.kind);
            try testing.expectEqualStrings(key, statement.key);
        } else {
            try testing.expect(statement.kind != .binding);
        }

        if (want.value) |value| {
            const found = statement.value orelse return error.TestUnexpectedResult;

            try testing.expectEqualStrings(value, found.unescape(&buffer));
        } else {
            try testing.expectEqual(@as(?Statement.Value, null), statement.value);
        }
    }

    const extra = scanner.next();

    try testing.expectEqual(@as(?Statement, null), extra);
}

const Single = struct {
    key: ?[]const u8,
    text: []const u8,
    value: ?[]const u8,
};

const upstream_singles = [_]Single{
    .{ .key = "a", .text = "a=b", .value = "b" },
    .{ .key = "a", .text = "'a'=b", .value = "b" },
    .{ .key = "[", .text = "[=b", .value = "b" },
    .{ .key = "a", .text = " a = b ", .value = "b" },
    .{ .key = "a", .text = "a=b\t#c", .value = "b" },
    .{ .key = "a", .text = "a=b#c", .value = "b#c" },
    .{ .key = "a", .text = "a=b\u{a0} c", .value = "b\u{a0} c" },
    .{ .key = "a", .text = "a=\"b\\\"c\"", .value = "b\"c" },
    .{ .key = "a", .text = "a='b\\nc'", .value = "b\\nc" },
    .{ .key = null, .text = "a: b", .value = null },
    .{ .key = "no_value_var", .text = "no_value_var", .value = null },
    .{ .key = "export_a", .text = "export export_a=1", .value = "1" },
};

test "the upstream parser cases scan to the bindings python-dotenv's tests state" {
    for (upstream_singles) |single| {
        const expected = Expected{
            .key = single.key,
            .line = 1,
            .original = single.text,
            .value = single.value,
        };

        try test_scan(single.text, &.{expected});
    }

    try test_scan("a=\"\nb=c", &.{
        .{ .key = null, .line = 1, .original = "a=\"\n", .value = null },
        .{ .key = "b", .line = 2, .original = "b=c", .value = "c" },
    });

    try test_scan("# comment\na=\"b\nc\"\nd=e\n", &.{
        .{ .key = null, .line = 1, .original = "# comment\n", .value = null },
        .{ .key = "a", .line = 2, .original = "a=\"b\nc\"\n", .value = "b\nc" },
        .{ .key = "d", .line = 4, .original = "d=e\n", .value = "e" },
    });

    try test_scan("uglyKey[%$=\"S3cr3t_P4ssw#rD\" #\na=b", &.{
        .{
            .key = "uglyKey[%$",
            .line = 1,
            .original = "uglyKey[%$=\"S3cr3t_P4ssw#rD\" #\n",
            .value = "S3cr3t_P4ssw#rD",
        },
        .{ .key = "a", .line = 2, .original = "a=b", .value = "b" },
    });
}

test "blank lines join the statement after them and trailing blanks end as trivia" {
    try test_scan("a=b\n\nc=d", &.{
        .{ .key = "a", .line = 1, .original = "a=b\n", .value = "b" },
        .{ .key = "c", .line = 2, .original = "\nc=d", .value = "d" },
    });

    try test_scan("a=b\n\n", &.{
        .{ .key = "a", .line = 1, .original = "a=b\n", .value = "b" },
        .{ .key = null, .line = 2, .original = "\n", .value = null },
    });

    try test_scan("\n\n", &.{.{ .key = null, .line = 1, .original = "\n\n", .value = null }});
}

test "a quoted value backtracks to its last escaped quote when no plain quote closes it" {
    try test_scan("A=\"a\\\"\nB=2\n", &.{
        .{ .key = "A", .line = 1, .original = "A=\"a\\\"\n", .value = "a\\" },
        .{ .key = "B", .line = 2, .original = "B=2\n", .value = "2" },
    });

    try test_scan("A=\"a\\\\\" # c\nX=\"y\"\n", &.{
        .{ .key = null, .line = 1, .original = "A=\"a\\\\\" # c\nX=\"y\"\n", .value = null },
    });
}

test "export needs whitespace after it and a key after that" {
    try test_scan("export\nexport  =1\nexport #c\nexportA=1\nexport ", &.{
        .{ .key = "export", .line = 1, .original = "export\n", .value = null },
        .{ .key = null, .line = 2, .original = "export  =1\n", .value = null },
        .{ .key = null, .line = 3, .original = "export #c\n", .value = null },
        .{ .key = "exportA", .line = 4, .original = "exportA=1\n", .value = "1" },
        .{ .key = null, .line = 5, .original = "export ", .value = null },
    });
}

test "an equals sign swallows the whitespace before a hash, which then belongs to the value" {
    try test_scan("A= #comment\nB=x #c\nC=x\u{a0}#c\n", &.{
        .{ .key = "A", .line = 1, .original = "A= #comment\n", .value = "#comment" },
        .{ .key = "B", .line = 2, .original = "B=x #c\n", .value = "x" },
        .{ .key = "C", .line = 3, .original = "C=x\u{a0}#c\n", .value = "x" },
    });
}

test "escapes decode in double quotes and only backslash and quote decode in single quotes" {
    try test_scan("A=\"\\a\\b\\f\\n\\r\\t\\v\\\\\\x\\$\"\nB='\\\\\\'\\n'\n", &.{
        .{
            .key = "A",
            .line = 1,
            .original = "A=\"\\a\\b\\f\\n\\r\\t\\v\\\\\\x\\$\"\n",
            .value = "\x07\x08\x0c\n\r\t\x0b\\\\x\\$",
        },
        .{ .key = "B", .line = 2, .original = "B='\\\\\\'\\n'\n", .value = "\\'\\n" },
    });
}

test "statements tile the text and every line number counts the newlines before it" {
    const text = "\u{feff}A=1\n  # c\n'k\ny'=\"v\nw\" #x\nbad line\n\n\nexport B=2\n\n";

    var scanner: Scanner = .init(text);
    var offset: u32 = 0;
    var count: u32 = 0;

    for (0..text.len) |_| {
        const statement = scanner.next() orelse break;
        const line: u32 = @intCast(std.mem.countScalar(u8, text[0..offset], '\n') + 1);
        const start = @intFromPtr(text.ptr) + offset;

        try testing.expectEqual(start, @intFromPtr(statement.original.ptr));
        try testing.expectEqual(line, statement.line);

        offset += @intCast(statement.original.len);
        count += 1;
    }

    try testing.expectEqual(@as(u32, text.len), offset);
    try testing.expectEqual(@as(u32, 6), count);
}

test "a statement's position is its first byte after the indent and any export" {
    const text = "A=1\n\n  B=2\n\t export \u{3000}C=3\n#c\n  \u{e9}x y\n\n";

    const expected = [_]Position{
        .{ .column = 1, .line = 1 },
        .{ .column = 3, .line = 3 },
        .{ .column = 11, .line = 4 },
        .{ .column = 1, .line = 5 },
        .{ .column = 3, .line = 6 },
        .{ .column = 1, .line = 8 },
    };

    var scanner: Scanner = .init(text);

    for (expected) |want| {
        const statement = scanner.next() orelse return error.TestUnexpectedResult;

        try testing.expectEqual(want, statement.position);
    }

    const extra = scanner.next();

    try testing.expectEqual(@as(?Statement, null), extra);
}

test Scanner {
    var scanner: Scanner = .init("# settings\nexport PORT=8080\nnot a binding\n");
    var buffer: [16]u8 = undefined;

    const comment = scanner.next() orelse return error.StatementMissing;
    const binding = scanner.next() orelse return error.StatementMissing;
    const failure = scanner.next() orelse return error.StatementMissing;
    const value = binding.value orelse return error.ValueMissing;

    try testing.expectEqual(Statement.Kind.trivia, comment.kind);
    try testing.expectEqualStrings("PORT", binding.key);
    try testing.expectEqualStrings("8080", value.unescape(&buffer));
    try testing.expectEqual(Position{ .column = 8, .line = 2 }, binding.position);
    try testing.expectEqual(Statement.Kind.failure, failure.kind);
    try testing.expectEqual(Position{ .column = 1, .line = 3 }, failure.position);

    const extra = scanner.next();

    try testing.expectEqual(@as(?Statement, null), extra);
}
