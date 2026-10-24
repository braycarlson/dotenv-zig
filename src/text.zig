const std = @import("std");

const assert = std.debug.assert;

pub const source_bytes_max: u32 = 1 << 24;

const whitespace_sequences = [_][]const u8{
    "\u{85}",
    "\u{a0}",
    "\u{1680}",
    "\u{2000}",
    "\u{2001}",
    "\u{2002}",
    "\u{2003}",
    "\u{2004}",
    "\u{2005}",
    "\u{2006}",
    "\u{2007}",
    "\u{2008}",
    "\u{2009}",
    "\u{200a}",
    "\u{2028}",
    "\u{2029}",
    "\u{202f}",
    "\u{205f}",
    "\u{3000}",
};

comptime {
    assert(source_bytes_max < std.math.maxInt(u32));
    assert(whitespace_sequences.len == 19);

    for (whitespace_sequences) |sequence| assert(sequence.len >= 2);
}

pub const Buffers = struct {
    source: []const u8,
    target: []const u8,
};

pub const DecodeError = error{
    TextExhausted,
    Utf8Invalid,
};

pub const DecodeOptions = struct {
    diagnostic: ?*Position = null,
};

pub const Position = struct {
    column: u32,
    line: u32,
};

pub fn decode(target: []u8, source: []const u8, options: DecodeOptions) DecodeError![]const u8 {
    comptime assert(@sizeOf(@TypeOf(options)) <= 16);

    assert(source.len <= source_bytes_max);
    assert(target.len < std.math.maxInt(u32));

    if (!std.unicode.utf8ValidateSlice(source)) {
        const invalid = utf8_invalid_index(source);

        if (options.diagnostic) |diagnostic| diagnostic.* = position_of(source, invalid);

        return error.Utf8Invalid;
    }

    const carriage = std.mem.findScalar(u8, source, '\r') orelse return source;

    if (target.len < source.len) {
        if (options.diagnostic) |diagnostic| diagnostic.* = position_of(source, @intCast(carriage));

        return error.TextExhausted;
    }

    const source_start = @intFromPtr(source.ptr);
    const target_start = @intFromPtr(target.ptr);

    if (target_start > source_start) assert(target_start >= source_start + source.len);

    std.mem.copyForwards(u8, target[0..carriage], source[0..carriage]);

    const length = newlines_translate(source, target, @intCast(carriage));
    const result = target[0..length];

    assert(result.len <= source.len);
    assert(std.mem.findScalar(u8, result, '\r') == null);

    return result;
}

fn newlines_translate(source: []const u8, target: []u8, start: u32) u32 {
    assert(start < source.len);
    assert(target.len >= source.len);
    assert(source[start] == '\r');

    var source_index: u32 = start;
    var target_index: u32 = start;

    for (0..source.len) |_| {
        if (source_index == source.len) break;

        const byte = source[source_index];

        source_index += 1;
        target[target_index] = if (byte == '\r') '\n' else byte;
        target_index += 1;

        if (byte != '\r') continue;
        if (source_index == source.len) break;

        if (source[source_index] == '\n') source_index += 1;
    }

    assert(source_index == source.len);
    assert(target_index <= source_index);

    return target_index;
}

fn utf8_invalid_index(source: []const u8) u32 {
    assert(source.len <= source_bytes_max);
    assert(!std.unicode.utf8ValidateSlice(source));

    var index: u32 = 0;

    for (0..source.len) |_| {
        if (index == source.len) break;

        const length = std.unicode.utf8ByteSequenceLength(source[index]) catch return index;
        if (length > source.len - index) return index;

        _ = std.unicode.utf8Decode(source[index..][0..length]) catch return index;

        index += length;
    }

    unreachable;
}

pub fn position_of(text: []const u8, offset: u32) Position {
    assert(offset <= text.len);
    assert(text.len <= source_bytes_max);

    var result: Position = .{ .column = 1, .line = 1 };

    for (text[0..offset], 0..) |byte, index| {
        switch (byte) {
            '\n' => result = .{ .column = 1, .line = result.line + 1 },
            '\r' => {
                const paired = std.mem.startsWith(u8, text[index + 1 ..], "\n");

                if (!paired) result = .{ .column = 1, .line = result.line + 1 };
            },
            0x80...0xbf => {},
            else => result.column += 1,
        }
    }

    assert(result.line > 0);
    assert(result.column > 0);

    return result;
}

pub fn whitespace_length(text: []const u8, offset: u32) u32 {
    assert(offset < text.len);
    assert(text.len <= source_bytes_max);

    const result: u32 = switch (text[offset]) {
        0x09...0x0d, 0x1c...0x20 => 1,
        0xc2, 0xe1, 0xe2, 0xe3 => sequence_length(text[offset..]),
        else => 0,
    };

    assert(result <= 3);

    return result;
}

fn sequence_length(rest: []const u8) u32 {
    assert(rest.len > 0);
    assert(rest[0] >= 0xc2);

    var result: u32 = 0;

    for (whitespace_sequences) |sequence| {
        if (!std.mem.startsWith(u8, rest, sequence)) continue;

        result = @intCast(sequence.len);

        break;
    }

    assert(result <= rest.len);

    return result;
}

pub fn whitespace_length_before(text: []const u8, end: u32) u32 {
    assert(end > 0);
    assert(end <= text.len);

    const before = text[0..end];

    switch (before[before.len - 1]) {
        0x09...0x0d, 0x1c...0x20 => return 1,
        0x80...0xbf => {},
        else => return 0,
    }

    var result: u32 = 0;

    for (whitespace_sequences) |sequence| {
        if (!std.mem.endsWith(u8, before, sequence)) continue;

        result = @intCast(sequence.len);

        break;
    }

    assert(result <= end);

    return result;
}

pub fn buffers_disjoint(buffers: *const Buffers) bool {
    assert(buffers.source.len <= source_bytes_max);
    assert(buffers.target.len < std.math.maxInt(u32));

    const source_start = @intFromPtr(buffers.source.ptr);
    const target_start = @intFromPtr(buffers.target.ptr);
    if (source_start + buffers.source.len <= target_start) return true;
    return target_start + buffers.target.len <= source_start;
}

pub fn trim_end(text: []const u8) []const u8 {
    assert(text.len <= source_bytes_max);

    var end: u32 = @intCast(text.len);

    for (0..text.len) |_| {
        if (end == 0) break;

        const length = whitespace_length_before(text, end);
        if (length == 0) break;

        end -= length;
    }

    const result = text[0..end];

    assert(result.len <= text.len);
    if (end > 0) assert(whitespace_length_before(text, end) == 0);

    return result;
}

const testing = std.testing;

const options_plain = DecodeOptions{ .diagnostic = null };

const python_whitespace = [_]u21{
    0x09,
    0x0a,
    0x0b,
    0x0c,
    0x0d,
    0x1c,
    0x1d,
    0x1e,
    0x1f,
    0x20,
    0x85,
    0xa0,
    0x1680,
    0x2000,
    0x2001,
    0x2002,
    0x2003,
    0x2004,
    0x2005,
    0x2006,
    0x2007,
    0x2008,
    0x2009,
    0x200a,
    0x2028,
    0x2029,
    0x202f,
    0x205f,
    0x3000,
};

fn python_space(codepoint: u21) bool {
    assert(codepoint <= 0x10ffff);
    assert(python_whitespace.len == 29);

    return std.mem.findScalar(u21, &python_whitespace, codepoint) != null;
}

test "every code point is whitespace exactly when Python's str.isspace says so" {
    var encoded: [4]u8 = undefined;

    for (0..0x110000) |position| {
        const codepoint: u21 = @intCast(position);

        if (codepoint >= 0xd800) {
            if (codepoint <= 0xdfff) continue;
        }

        const length = try std.unicode.utf8Encode(codepoint, &encoded);
        const text = encoded[0..length];
        const expected: u32 = if (python_space(codepoint)) length else 0;

        try testing.expectEqual(expected, whitespace_length(text, 0));
        try testing.expectEqual(expected, whitespace_length_before(text, length));
    }
}

test "a whitespace check reads one character and never runs past the text" {
    try testing.expectEqual(@as(u32, 0), whitespace_length("\xc2", 0));
    try testing.expectEqual(@as(u32, 0), whitespace_length("\xe2\x80", 0));
    try testing.expectEqual(@as(u32, 2), whitespace_length("a\u{a0}b", 1));
    try testing.expectEqual(@as(u32, 0), whitespace_length("a\u{a0}b", 2));
    try testing.expectEqual(@as(u32, 3), whitespace_length_before("x\u{3000}", 4));
    try testing.expectEqual(@as(u32, 0), whitespace_length_before("\u{e9}", 2));
}

test "trim_end strips Python whitespace from the end and nothing else" {
    try testing.expectEqualStrings("a b", trim_end("a b \t\u{a0}\u{2028}\x0b"));
    try testing.expectEqualStrings("", trim_end(" \u{3000} "));
    try testing.expectEqualStrings("\u{e9}", trim_end("\u{e9}\u{85}"));
    try testing.expectEqualStrings("x\u{200b}", trim_end("x\u{200b}"));
    try testing.expectEqualStrings("", trim_end(""));
}

test "decode keeps a text without carriage returns and translates the rest like Python" {
    var target: [32]u8 = undefined;

    const plain = "A=1\nB=2\n";
    const kept = try decode(&target, plain, options_plain);

    try testing.expectEqual(plain.ptr, kept.ptr);

    const mixed = try decode(&target, "A=1\r\nB=\"x\r\ny\"\rC=3\r", options_plain);

    try testing.expectEqualStrings("A=1\nB=\"x\ny\"\nC=3\n", mixed);
    try testing.expectEqualStrings("\n\n\n", try decode(&target, "\r\r\n\n", options_plain));
    try testing.expectEqualStrings("a\n", try decode(&target, "a\r", options_plain));
}

test "decode translates in place and refuses a target too small for a copy" {
    var buffer = "K=v\r\n\r\nL=w\r".*;

    const translated = try decode(&buffer, &buffer, options_plain);

    try testing.expectEqualStrings("K=v\n\nL=w\n", translated);
    try testing.expectEqual(@intFromPtr(&buffer), @intFromPtr(translated.ptr));

    var small: [3]u8 = undefined;

    try testing.expectError(error.TextExhausted, decode(&small, "A=1\r\n", options_plain));
    try testing.expectEqualStrings("A=1\n", try decode(&small, "A=1\n", options_plain));
}

const invalid_samples = [_][]const u8{
    "\x80",
    "a\xc3",
    "\xc0\xaf",
    "\xe0\x80\xaf",
    "\xed\xa0\x80",
    "\xf4\x90\x80\x80",
    "\xf5\x80\x80\x80",
    "\xff",
};

test "decode refuses what Python's strict UTF-8 decoder refuses" {
    var target: [16]u8 = undefined;

    for (invalid_samples) |source| {
        try testing.expectError(error.Utf8Invalid, decode(&target, source, options_plain));
    }

    const marked = "\u{feff}A=\u{10ffff}";

    try testing.expectEqualStrings(marked, try decode(&target, marked, options_plain));
}

const PositionCase = struct {
    expected: Position,
    source: []const u8,
};

test "decode places an invalid byte by Python's lines and by code point columns" {
    var target: [64]u8 = undefined;

    const cases = [_]PositionCase{
        .{ .expected = .{ .column = 1, .line = 1 }, .source = "\xffA=1" },
        .{ .expected = .{ .column = 3, .line = 2 }, .source = "A=1\nB=\xff\n" },
        .{ .expected = .{ .column = 3, .line = 2 }, .source = "A=1\r\nB=\xff\r\n" },
        .{ .expected = .{ .column = 3, .line = 3 }, .source = "A=1\r\rB=\xff" },
        .{ .expected = .{ .column = 4, .line = 1 }, .source = "A=\u{e9}\xc3" },
        .{ .expected = .{ .column = 4, .line = 2 }, .source = "\n\u{3000}\u{1f600}=\xed\xa0" },
    };

    for (cases) |case| {
        var diagnostic: Position = undefined;

        const decoded = decode(&target, case.source, .{ .diagnostic = &diagnostic });

        try testing.expectError(error.Utf8Invalid, decoded);
        try testing.expectEqual(case.expected, diagnostic);
    }
}

test "decode places a refused copy at the carriage return that forced it" {
    var small: [8]u8 = undefined;
    var diagnostic: Position = undefined;

    const decoded = decode(&small, "A=1\nB=\u{e9}\r\nC=3\n", .{ .diagnostic = &diagnostic });

    try testing.expectError(error.TextExhausted, decoded);
    try testing.expectEqual(Position{ .column = 4, .line = 2 }, diagnostic);

    var untouched = Position{ .column = 7, .line = 7 };

    _ = try decode(&small, "A=1\r\n", .{ .diagnostic = &untouched });

    try testing.expectEqual(Position{ .column = 7, .line = 7 }, untouched);
}

test "the first invalid byte is where the longest valid prefix ends" {
    for (invalid_samples) |sample| {
        var buffer: [16]u8 = undefined;

        const prefix = "x\u{e9}y";
        const source = try std.mem.print(&buffer, "{s}{s}z", .{ prefix, sample });

        var valid_length: u32 = 0;

        for (0..source.len + 1) |length| {
            if (std.unicode.utf8ValidateSlice(source[0..length])) valid_length = @intCast(length);
        }

        try testing.expectEqual(valid_length, utf8_invalid_index(source));
        try testing.expect(valid_length >= prefix.len);
    }
}

test "a position counts a carriage return pair as one line break and a code point as one column" {
    try testing.expectEqual(Position{ .column = 1, .line = 1 }, position_of("", 0));
    try testing.expectEqual(Position{ .column = 3, .line = 1 }, position_of("ab\r\nc", 2));
    try testing.expectEqual(Position{ .column = 3, .line = 1 }, position_of("ab\r\nc", 3));
    try testing.expectEqual(Position{ .column = 1, .line = 2 }, position_of("ab\r\nc", 4));
    try testing.expectEqual(Position{ .column = 1, .line = 3 }, position_of("a\r\rc", 3));
    try testing.expectEqual(Position{ .column = 3, .line = 1 }, position_of("\u{e9}\u{4e2d}x", 5));
}

test decode {
    var target: [64]u8 = undefined;

    const text = try decode(&target, "A=1\r\nB=2\r\n", options_plain);

    try testing.expectEqualStrings("A=1\nB=2\n", text);

    var diagnostic: Position = undefined;

    const refused = decode(&target, "A=1\nB=\xff\n", .{ .diagnostic = &diagnostic });

    try testing.expectError(error.Utf8Invalid, refused);
    try testing.expectEqual(Position{ .column = 3, .line = 2 }, diagnostic);
}
