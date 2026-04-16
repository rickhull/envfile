// lint.zig — validate env files (see README.md)

const std = @import("std");
const Io = std.Io;

const ERROR_NO_EQUALS                 = "missing assignment (=)";
const ERROR_KEY_LEADING_WHITESPACE    = "leading whitespace before key";
const ERROR_KEY_TRAILING_WHITESPACE   = "whitespace before =";
const ERROR_VALUE_LEADING_WHITESPACE  = "whitespace after =";
const ERROR_KEY_INVALID               = "invalid key";
const ERROR_DOUBLE_QUOTE_UNTERMINATED = "unterminated double quote";
const ERROR_SINGLE_QUOTE_UNTERMINATED = "unterminated single quote";
const ERROR_TRAILING_CONTENT          = "trailing content after closing quote";
const ERROR_VALUE_INVALID_CHAR        = "value contains whitespace, quote, or backslash";
const WARN_KEY_NOT_UPPERCASE          = "is not UPPERCASE (preferred)";

const Counts = struct {
    checked: u32 = 0,
    errors: u32 = 0,
    warnings: u32 = 0,
};

fn isKeyStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isKeyRest(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isBadValChar(c: u8) bool {
    return std.ascii.isWhitespace(c) or c == '\'' or c == '"' or c == '\\';
}

fn lintFile(
    path: []const u8,
    io: Io,
    stderr: *Io.Writer,
    counts: *Counts,
) !void {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        try stderr.print("lint: {s}: {}\n", .{ path, err });
        counts.errors += 1;
        return;
    };
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var file_reader: Io.File.Reader = .init(file, io, &read_buf);
    const reader = &file_reader.interface;

    var n: u32 = 0;

    while (try reader.takeDelimiter('\n')) |raw| {
        n += 1;

        // strip \r for Windows line endings
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

        // skip blank and comment lines
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (line[0] == '#') continue;
        counts.checked += 1;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            try stderr.print("{s}:{d}: {s}\n", .{ path, n, ERROR_NO_EQUALS });
            counts.errors += 1;
            continue;
        };

        const k = line[0..eq];
        const v = line[eq + 1 ..];

        if (k.len > 0 and std.ascii.isWhitespace(k[0])) {
            try stderr.print("{s}:{d}: {s}\n", .{ path, n, ERROR_KEY_LEADING_WHITESPACE });
            counts.errors += 1;
            continue;
        }
        if (k.len > 0 and std.ascii.isWhitespace(k[k.len - 1])) {
            try stderr.print("{s}:{d}: {s}\n", .{ path, n, ERROR_KEY_TRAILING_WHITESPACE });
            counts.errors += 1;
            continue;
        }
        if (v.len > 0 and std.ascii.isWhitespace(v[0])) {
            try stderr.print("{s}:{d}: {s}\n", .{ path, n, ERROR_VALUE_LEADING_WHITESPACE });
            counts.errors += 1;
            continue;
        }

        // validate key
        var key_ok = k.len > 0 and isKeyStart(k[0]);
        if (key_ok) {
            for (k[1..]) |c| {
                if (!isKeyRest(c)) { key_ok = false; break; }
            }
        }
        if (!key_ok) {
            try stderr.print("{s}:{d}: {s} '{s}'\n", .{ path, n, ERROR_KEY_INVALID, k });
            counts.errors += 1;
            continue;
        }

        // warn if not uppercase
        var all_upper = true;
        for (k) |c| {
            if (std.ascii.isAlphabetic(c) and !std.ascii.isUpper(c)) { all_upper = false; break; }
        }
        if (!all_upper) {
            try stderr.print("{s}:{d}: key '{s}' {s}\n", .{ path, n, k, WARN_KEY_NOT_UPPERCASE });
            counts.warnings += 1;
        }

        if (v.len == 0) continue;

        switch (v[0]) {
            '"' => {
                const rest = v[1..];
                const pos = std.mem.indexOfScalar(u8, rest, '"') orelse {
                    try stderr.print("{s}:{d}: {s}\n", .{ path, n, ERROR_DOUBLE_QUOTE_UNTERMINATED });
                    counts.errors += 1;
                    continue;
                };
                if (rest[pos + 1 ..].len > 0) {
                    try stderr.print("{s}:{d}: {s}\n", .{ path, n, ERROR_TRAILING_CONTENT });
                    counts.errors += 1;
                    continue;
                }
            },
            '\'' => {
                const rest = v[1..];
                const pos = std.mem.indexOfScalar(u8, rest, '\'') orelse {
                    try stderr.print("{s}:{d}: {s}\n", .{ path, n, ERROR_SINGLE_QUOTE_UNTERMINATED });
                    counts.errors += 1;
                    continue;
                };
                if (rest[pos + 1 ..].len > 0) {
                    try stderr.print("{s}:{d}: {s}\n", .{ path, n, ERROR_TRAILING_CONTENT });
                    counts.errors += 1;
                    continue;
                }
            },
            else => {
                for (v) |c| {
                    if (isBadValChar(c)) {
                        try stderr.print("{s}:{d}: {s}\n", .{ path, n, ERROR_VALUE_INVALID_CHAR });
                        counts.errors += 1;
                        break;
                    }
                }
                // re-check if we emitted an error to skip the rest
                var had_bad = false;
                for (v) |c| { if (isBadValChar(c)) { had_bad = true; break; } }
                if (had_bad) continue;
            },
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stderr = &stderr_file_writer.interface;
    defer stderr.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        try stderr.print("lint: no files specified\n", .{});
        std.process.exit(1);
    }

    var total = Counts{};
    for (args[1..]) |path| {
        var c = Counts{};
        try lintFile(path, io, stderr, &c);
        total.checked += c.checked;
        total.errors += c.errors;
        total.warnings += c.warnings;
    }

    try stderr.print("{d} checked, {d} errors, {d} warnings\n",
        .{ total.checked, total.errors, total.warnings });
    try stderr.flush();

    if (total.errors > 0) std.process.exit(1);
}
