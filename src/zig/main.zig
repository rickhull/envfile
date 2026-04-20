// main.zig — validate/normalize env files (see README.md)

const std = @import("std");
const Io  = std.Io;

const ERROR_NO_EQUALS                 = "ERROR_NO_EQUALS";
const ERROR_EMPTY_KEY                 = "ERROR_EMPTY_KEY";
const ERROR_KEY_LEADING_WHITESPACE    = "ERROR_KEY_LEADING_WHITESPACE";
const ERROR_KEY_TRAILING_WHITESPACE   = "ERROR_KEY_TRAILING_WHITESPACE";
const ERROR_VALUE_LEADING_WHITESPACE  = "ERROR_VALUE_LEADING_WHITESPACE";
const ERROR_KEY_INVALID               = "ERROR_KEY_INVALID";
const ERROR_DOUBLE_QUOTE_UNTERMINATED = "ERROR_DOUBLE_QUOTE_UNTERMINATED";
const ERROR_SINGLE_QUOTE_UNTERMINATED = "ERROR_SINGLE_QUOTE_UNTERMINATED";
const ERROR_TRAILING_CONTENT          = "ERROR_TRAILING_CONTENT";
const ERROR_VALUE_INVALID_CHAR        = "ERROR_VALUE_INVALID_CHAR";

// --- character classifiers ---

fn isNativeKeyStart(c: u8) bool { return (c >= 'A' and c <= 'Z') or c == '_'; }
fn isNativeKeyRest(c: u8)  bool { return (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_'; }
fn isShellKeyStart(c: u8) bool { return std.ascii.isAlphabetic(c) or c == '_'; }
fn isShellKeyRest(c: u8)  bool { return std.ascii.isAlphanumeric(c) or c == '_'; }
fn isBadValChar(c: u8)     bool { return std.ascii.isWhitespace(c) or c == '\'' or c == '"' or c == '\\'; }

fn buildByteTable(comptime pred: fn (u8) bool) [256]bool {
    var table: [256]bool = [_]bool{false} ** 256;
    var i: usize = 0;
    while (i < table.len) : (i += 1) {
        table[i] = pred(@as(u8, @intCast(i)));
    }
    return table;
}

const native_key_start = buildByteTable(isNativeKeyStart);
const native_key_rest  = buildByteTable(isNativeKeyRest);
const shell_key_start = buildByteTable(isShellKeyStart);
const shell_key_rest  = buildByteTable(isShellKeyRest);
const bad_val_table    = buildByteTable(isBadValChar);

fn validKey(
    comptime start_table: *const [256]bool,
    comptime rest_table: *const [256]bool,
    k: []const u8,
) bool {
    if (k.len == 0 or !start_table[k[0]]) return false;
    for (k[1..]) |c| if (!rest_table[c]) return false;
    return true;
}

fn validNativeKey(k: []const u8) bool {
    return validKey(&native_key_start, &native_key_rest, k);
}

fn validShellKey(k: []const u8) bool {
    return validKey(&shell_key_start, &shell_key_rest, k);
}

fn hasBadValueByte(v: []const u8) bool {
    for (v) |c| if (bad_val_table[c]) return true;
    return false;
}

// --- counts ---

const Counts = struct {
    checked:  u32 = 0,
    errors:   u32 = 0,
};

// --- native core: slurp and scan ---

// Returns (checked, errors) for one record slice (no newline).
fn nativeRecord(
    line:      []const u8,
    tag:       []const u8,
    n:         u32,
    diag:      *Io.Writer,
    norm:      *Io.Writer,
    normalize: bool,
) !struct { u32, u32 } {
    if (std.mem.indexOfScalar(u8, line, 0) != null) {
        diag.print("{s}: {s}:{d}\n", .{ ERROR_VALUE_INVALID_CHAR, tag, n }) catch {};
        return .{ 1, 1 };
    }

    var blank = true;
    for (line) |c| if (!std.ascii.isWhitespace(c)) { blank = false; break; };
    if (blank or line[0] == '#') return .{ 0, 0 };

    const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
        diag.print("{s}: {s}:{d}\n", .{ ERROR_NO_EQUALS, tag, n }) catch {};
        return .{ 1, 1 };
    };
    const k = line[0..eq];
    const v = line[eq + 1..];

    if (k.len == 0) {
        diag.print("{s}: {s}:{d}\n", .{ ERROR_EMPTY_KEY, tag, n }) catch {};
        return .{ 1, 1 };
    }
    if (!validNativeKey(k)) {
        diag.print("{s}: {s}:{d}\n", .{ ERROR_KEY_INVALID, tag, n }) catch {};
        return .{ 1, 1 };
    }
    if (normalize) try norm.print("{s}={s}\n", .{ k, v });
    return .{ 1, 0 };
}

fn nativeScan(
    buf:       []const u8,
    tag:       []const u8,
    diag:      *Io.Writer,
    norm:      *Io.Writer,
    normalize: bool,
    counts:    *Counts,
    n:         *u32,
) !void {
    var pos: usize = 0;
    while (pos <= buf.len) {
        const nl  = std.mem.indexOfScalarPos(u8, buf, pos, '\n');
        const end = if (nl) |i| i else buf.len;
        if (end > pos or nl != null) {
            n.* += 1;
            const chk, const err = try nativeRecord(buf[pos..end], tag, n.*, diag, norm, normalize);
            counts.checked += chk;
            counts.errors  += err;
        }
        if (nl == null) break;
        pos = end + 1;
    }
}

// --- shell core: line-oriented ---

const LineResult = struct {
    diag:  ?[]const u8 = null,
    fatal: bool        = false,
    val:   []const u8  = "",
};

fn shellLine(line: []const u8) LineResult {
    if (std.mem.indexOfScalar(u8, line, 0) != null) {
        return .{ .diag = ERROR_VALUE_INVALID_CHAR, .fatal = true };
    }

    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return .{ .diag = ERROR_NO_EQUALS,               .fatal = true };
    const k  = line[0..eq];
    const v  = line[eq + 1..];

    if (k.len > 0 and std.ascii.isWhitespace(k[0]))       return .{ .diag = ERROR_KEY_LEADING_WHITESPACE,   .fatal = true };
    if (k.len > 0 and std.ascii.isWhitespace(k[k.len-1])) return .{ .diag = ERROR_KEY_TRAILING_WHITESPACE,  .fatal = true };
    if (v.len > 0 and std.ascii.isWhitespace(v[0]))        return .{ .diag = ERROR_VALUE_LEADING_WHITESPACE, .fatal = true };
    if (k.len == 0)                                        return .{ .diag = ERROR_EMPTY_KEY,               .fatal = true };
    if (!validShellKey(k))                                 return .{ .diag = ERROR_KEY_INVALID,              .fatal = true };

    const val = val: {
        if (v.len == 0) break :val v;
        const q = v[0];
        if (q == '"' or q == '\'') {
            const rest = v[1..];
            const pos  = std.mem.indexOfScalar(u8, rest, q) orelse
                return .{ .diag = if (q == '"') ERROR_DOUBLE_QUOTE_UNTERMINATED else ERROR_SINGLE_QUOTE_UNTERMINATED, .fatal = true };
            if (rest[pos + 1..].len > 0) return .{ .diag = ERROR_TRAILING_CONTENT, .fatal = true };
            break :val rest[0..pos];
        }
        if (hasBadValueByte(v)) return .{ .diag = ERROR_VALUE_INVALID_CHAR, .fatal = true };
        break :val v;
    };

    return .{ .val = val };
}

// --- IO helpers ---

fn isBlank(line: []const u8) bool {
    for (line) |c| if (!std.ascii.isWhitespace(c)) return false;
    return true;
}

fn openPath(path: []const u8, io: Io) !Io.File {
    if (std.mem.eql(u8, path, "-")) return Io.File.stdin();
    return std.Io.Dir.cwd().openFile(io, path, .{});
}

// --- file linting ---

fn lintNative(
    path:      []const u8,
    io:        Io,
    norm:      *Io.Writer,
    diag:      *Io.Writer,
    normalize: bool,
    counts:    *Counts,
) !void {
    const file = openPath(path, io) catch |err| {
        diag.print("lint: {s}: {}\n", .{ path, err }) catch {};
        counts.errors += 1;
        return;
    };
    defer if (!std.mem.eql(u8, path, "-")) file.close(io);

    var read_buf: [4096]u8 = undefined;
    var fr: Io.File.Reader = .initStreaming(file, io, &read_buf);
    const r = &fr.interface;

    var buf: [65536]u8 = undefined;

    var tail: usize = 0; // bytes carried over from previous chunk
    var line_n: u32 = 0; // line counter, passed into nativeScan by ref

    while (true) {
        const n = r.readSliceShort(buf[tail..]) catch |err| switch (err) {
            error.ReadFailed => return err,
        };
        const filled = tail + n;
        const eof = n == 0;

        if (filled == 0) break;

        if (eof) {
            // no trailing newline: process final record as-is
            try nativeScan(buf[0..filled], path, diag, norm, normalize, counts, &line_n);
            break;
        }

        // find last newline so we only process complete records
        const last_nl = std.mem.lastIndexOfScalar(u8, buf[0..filled], '\n');
        if (last_nl == null) {
            // entire buffer is one partial record — too long to handle
            diag.print("ERROR_LINE_TOO_LONG: {s}\n", .{path}) catch {};
            counts.errors += 1;
            return;
        }

        const complete = last_nl.? + 1;
        try nativeScan(buf[0..complete], path, diag, norm, normalize, counts, &line_n);

        // move unfinished tail to front
        tail = filled - complete;
        std.mem.copyForwards(u8, buf[0..tail], buf[complete..filled]);
    }
}

fn lintShell(
    path:      []const u8,
    io:        Io,
    norm:      *Io.Writer,
    diag:      *Io.Writer,
    normalize: bool,
    counts:    *Counts,
) !void {
    const file = openPath(path, io) catch |err| {
        diag.print("lint: {s}: {}\n", .{ path, err }) catch {};
        counts.errors += 1;
        return;
    };
    defer if (!std.mem.eql(u8, path, "-")) file.close(io);

    var buf: [65536]u8 = undefined;
    var fr: Io.File.Reader = .init(file, io, &buf);
    const r = &fr.interface;

    var n: u32 = 0;
    while (try r.takeDelimiter('\n')) |raw| {
        n += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (isBlank(line) or (line.len > 0 and line[0] == '#')) continue;
        counts.checked += 1;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse 0;
        const k  = line[0..eq];
        const sr = shellLine(line);
        if (sr.diag) |code| {
            diag.print("{s}: {s}:{d}\n", .{ code, path, n }) catch {};
            if (sr.fatal) { counts.errors += 1; continue; }
        }
        if (normalize) try norm.print("{s}={s}\n", .{ k, sr.val });
    }
}

// --- main ---

pub fn main(init: std.process.Init) !void {
    const io    = init.io;
    const arena = init.arena.allocator();

    const format    = init.environ_map.get("ENVFILE_FORMAT") orelse "shell";
    const action    = init.environ_map.get("ENVFILE_ACTION") orelse "validate";
    const native    = std.mem.eql(u8, format, "native");
    const normalize = std.mem.eql(u8, action, "normalize");

    var norm_buf: [65536]u8 = undefined;
    var norm_writer: Io.File.Writer = .init(.stdout(), io, &norm_buf);
    const norm = &norm_writer.interface;

    var diag_buf: [4096]u8 = undefined;
    var diag_writer: Io.File.Writer = .init(.stderr(), io, &diag_buf);
    const diag = &diag_writer.interface;

    const args  = try init.minimal.args.toSlice(arena);
    const files = if (args.len > 1) args[1..] else &[_][]const u8{"-"};

    var total = Counts{};
    for (files) |path| {
        var c = Counts{};
        if (native) try lintNative(path, io, norm, diag, normalize, &c)
        else        try lintShell(path, io,      norm, diag, normalize, &c);
        total.checked  += c.checked;
        total.errors   += c.errors;
    }

    try diag.print("{d} checked, {d} errors\n",
        .{ total.checked, total.errors });
    norm.flush() catch {};
    diag.flush() catch {};

    if (total.errors > 0) std.process.exit(1);
}
