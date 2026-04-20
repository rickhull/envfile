// main.zig — envfile zig implementation

const std = @import("std");
const Io = std.Io;

const Action = enum {
    normalize,
    validate,
    dump,
    delta,
    apply,
};

const BomMode = enum {
    literal,
    strip,
    reject,
};

const Counts = struct {
    checked: u32 = 0,
    errors: u32 = 0,
};

const EnvEntry = struct {
    key: []const u8,
    value: []const u8,
};

const EnvStore = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(EnvEntry),

    fn init(allocator: std.mem.Allocator) EnvStore {
        return .{
            .allocator = allocator,
            .entries = .empty,
        };
    }

    fn get(self: *const EnvStore, key: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }

    fn set(self: *EnvStore, key: []const u8, value: []const u8) !void {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                entry.value = value;
                return;
            }
        }
        try self.entries.append(self.allocator, .{
            .key = key,
            .value = value,
        });
    }

    fn seedFromProcess(self: *EnvStore, env: anytype) !void {
        var it = env.iterator();
        while (it.next()) |kv| {
            if (std.mem.startsWith(u8, kv.key_ptr.*, "ENVFILE_")) continue;
            try self.entries.append(self.allocator, .{
                .key = try self.allocator.dupe(u8, kv.key_ptr.*),
                .value = try self.allocator.dupe(u8, kv.value_ptr.*),
            });
        }
    }

    fn emitSorted(self: *const EnvStore, stdout: *Io.Writer) !void {
        const Ctx = struct {
            items: []const EnvEntry,
        };
        const Less = struct {
            fn less(ctx: Ctx, a: usize, b: usize) bool {
                return std.mem.lessThan(u8, ctx.items[a].key, ctx.items[b].key);
            }
        };

        var idx: std.ArrayList(usize) = .empty;
        defer idx.deinit(self.allocator);

        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.startsWith(u8, entry.key, "ENVFILE_")) continue;
            try idx.append(self.allocator, i);
        }

        std.sort.heap(usize, idx.items, Ctx{ .items = self.entries.items }, Less.less);

        for (idx.items) |i| {
            const entry = self.entries.items[i];
            try stdout.print("{s}={s}\n", .{ entry.key, entry.value });
        }
    }
};

fn fatal(stderr: *Io.Writer, code: []const u8, detail: []const u8) noreturn {
    stderr.print("{s}: {s}\n", .{ code, detail }) catch {};
    stderr.flush() catch {};
    std.process.exit(1);
}

fn parseAction(stderr: *Io.Writer, raw: []const u8) Action {
    if (std.mem.eql(u8, raw, "normalize")) return .normalize;
    if (std.mem.eql(u8, raw, "validate")) return .validate;
    if (std.mem.eql(u8, raw, "dump")) return .dump;
    if (std.mem.eql(u8, raw, "delta")) return .delta;
    if (std.mem.eql(u8, raw, "apply")) return .apply;
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "action={s}", .{raw}) catch "action=<invalid>";
    fatal(stderr, "FATAL_ERROR_BAD_ARG", msg);
}

fn parseBom(stderr: *Io.Writer, format: []const u8, raw_opt: ?[]const u8) BomMode {
    const raw = raw_opt orelse if (std.mem.eql(u8, format, "native")) "literal" else "strip";

    if (std.mem.eql(u8, raw, "literal")) return .literal;
    if (std.mem.eql(u8, raw, "strip")) return .strip;
    if (std.mem.eql(u8, raw, "reject")) return .reject;

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "ENVFILE_BOM={s}", .{raw}) catch "ENVFILE_BOM=<invalid>";
    fatal(stderr, "FATAL_ERROR_BAD_ENVFILE_VALUE", msg);
}

fn isIdentifierStart(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
}

fn isIdentifierRest(c: u8) bool {
    return isIdentifierStart(c) or (c >= '0' and c <= '9');
}

fn isShellKeyStart(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
}

fn isShellKeyRest(c: u8) bool {
    return isShellKeyStart(c) or (c >= '0' and c <= '9');
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

fn validShellKey(key: []const u8) bool {
    if (key.len == 0 or !isShellKeyStart(key[0])) return false;
    for (key[1..]) |c| if (!isShellKeyRest(c)) return false;
    return true;
}

fn trimTrailingCR(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn isBlank(line: []const u8) bool {
    for (line) |c| if (!isWhitespace(c)) return false;
    return true;
}

fn containsBadShellValueByte(value: []const u8) bool {
    for (value) |c| {
        if (c == ' ' or c == '\t' or c == '\'' or c == '"' or c == '\\') return true;
    }
    return false;
}

fn isContinuation(line: []const u8) bool {
    var i = line.len;
    var n: usize = 0;
    while (i > 0 and line[i - 1] == '\\') : (i -= 1) n += 1;
    return (n % 2) == 1;
}

fn openPath(path: []const u8, io: Io) !Io.File {
    if (std.mem.eql(u8, path, "-")) return Io.File.stdin();
    return std.Io.Dir.cwd().openFile(io, path, .{});
}

fn readAllPath(allocator: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    const file = try openPath(path, io);
    defer if (!std.mem.eql(u8, path, "-")) file.close(io);

    var reader_buf: [4096]u8 = undefined;
    var fr: Io.File.Reader = .initStreaming(file, io, &reader_buf);
    const r = &fr.interface;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = r.readSliceShort(tmp[0..]) catch |err| switch (err) {
            error.ReadFailed => return err,
        };
        if (n == 0) break;
        try out.appendSlice(allocator, tmp[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

fn splitLines(allocator: std.mem.Allocator, buf: []u8) !std.ArrayList([]const u8) {
    var lines: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        if (buf[i] == '\n') {
            try lines.append(allocator, buf[start..i]);
            start = i + 1;
        }
    }
    if (start < buf.len) try lines.append(allocator, buf[start..]);
    return lines;
}

fn substValue(
    allocator: std.mem.Allocator,
    value: []const u8,
    path: []const u8,
    lineno: u32,
    env: *const EnvStore,
    stderr: *Io.Writer,
    counts: *Counts,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < value.len) {
        const rel = std.mem.indexOfScalarPos(u8, value, i, '$');
        if (rel == null) {
            try out.appendSlice(allocator, value[i..]);
            break;
        }

        const pos = rel.?;
        try out.appendSlice(allocator, value[i..pos]);

        const after = pos + 1;
        if (after >= value.len) {
            try out.append(allocator, '$');
            break;
        }

        if (value[after] == '{') {
            const tail = value[after + 1 ..];
            const close_rel = std.mem.indexOfScalar(u8, tail, '}');
            if (close_rel == null) {
                try out.append(allocator, '$');
                try out.appendSlice(allocator, value[after..]);
                break;
            }
            const close = close_rel.?;
            const name = tail[0..close];
            i = after + 1 + close + 1;

            if (env.get(name)) |v| {
                try out.appendSlice(allocator, v);
            } else {
                try stderr.print("LINE_ERROR_UNBOUND_REF ({s}): {s}:{d}\n", .{ name, path, lineno });
                counts.errors += 1;
            }
            continue;
        }

        if (!isIdentifierStart(value[after])) {
            try out.append(allocator, '$');
            i = after;
            continue;
        }

        var end = after + 1;
        while (end < value.len and isIdentifierRest(value[end])) : (end += 1) {}
        const name = value[after..end];
        i = end;

        if (env.get(name)) |v| {
            try out.appendSlice(allocator, v);
        } else {
            try stderr.print("LINE_ERROR_UNBOUND_REF ({s}): {s}:{d}\n", .{ name, path, lineno });
            counts.errors += 1;
        }
    }

    return out.toOwnedSlice(allocator);
}

fn handleRecord(
    allocator: std.mem.Allocator,
    action: Action,
    native: bool,
    key: []const u8,
    raw_value: []const u8,
    value: []const u8,
    path: []const u8,
    lineno: u32,
    env: *EnvStore,
    stderr: *Io.Writer,
    stdout: *Io.Writer,
    counts: *Counts,
) !void {
    switch (action) {
        .dump => {
            try stdout.print("{s}={s}\n", .{ key, value });
            return;
        },
        .validate, .normalize => return,
        .delta, .apply => {},
    }

    var resolved = value;
    if (native or !(raw_value.len > 0 and raw_value[0] == '\'')) {
        resolved = try substValue(allocator, value, path, lineno, env, stderr, counts);
    }

    try env.set(key, resolved);
    if (action == .delta) try stdout.print("{s}={s}\n", .{ key, resolved });
}

fn processOneFile(
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
    action: Action,
    native: bool,
    bom: BomMode,
    crlf: []const u8,
    nul: []const u8,
    cont: []const u8,
    env: *EnvStore,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    counts: *Counts,
) !void {
    const buf = readAllPath(allocator, io, path) catch {
        try stderr.print("FILE_ERROR_FILE_UNREADABLE: {s}\n", .{path});
        counts.errors += 1;
        return;
    };

    if (std.mem.eql(u8, nul, "reject") and std.mem.indexOfScalar(u8, buf, 0) != null) {
        try stderr.print("FILE_ERROR_NUL: {s}\n", .{path});
        counts.errors += 1;
        return;
    }

    var lines = try splitLines(allocator, buf);

    if (lines.items.len > 0 and std.mem.startsWith(u8, lines.items[0], "\xEF\xBB\xBF")) {
        switch (bom) {
            .reject => {
                try stderr.print("FILE_ERROR_BOM: {s}\n", .{path});
                counts.errors += 1;
                return;
            },
            .strip => {
                lines.items[0] = lines.items[0][3..];
            },
            .literal => {},
        }
    }

    if (std.mem.eql(u8, crlf, "strip")) {
        var all_crlf = true;
        for (lines.items) |line| {
            if (line.len == 0 or line[line.len - 1] != '\r') {
                all_crlf = false;
                break;
            }
        }
        if (all_crlf) {
            for (lines.items) |*line| line.* = line.*[0 .. line.len - 1];
        }
    }

    var proc_lines: std.ArrayList([]const u8) = .empty;
    var proc_lineno: std.ArrayList(u32) = .empty;

    if (std.mem.eql(u8, cont, "accept")) {
        var i: usize = 0;
        while (i < lines.items.len) {
            var line = lines.items[i];
            var lineno: u32 = @intCast(i + 1);
            i += 1;
            if (isContinuation(line)) {
                var joined: std.ArrayList(u8) = .empty;
                defer joined.deinit(allocator);
                try joined.appendSlice(allocator, line[0 .. line.len - 1]);

                while (i < lines.items.len) {
                    const next = lines.items[i];
                    lineno = @intCast(i + 1);
                    i += 1;
                    if (isContinuation(next)) {
                        try joined.appendSlice(allocator, next[0 .. next.len - 1]);
                    } else {
                        try joined.appendSlice(allocator, next);
                        break;
                    }
                }
                line = try joined.toOwnedSlice(allocator);
            }
            try proc_lines.append(allocator, line);
            try proc_lineno.append(allocator, lineno);
        }
    } else {
        for (lines.items, 0..) |line, i| {
            try proc_lines.append(allocator, line);
            try proc_lineno.append(allocator, @intCast(i + 1));
        }
    }

    for (proc_lines.items, 0..) |line, idx| {
        const lineno = proc_lineno.items[idx];
        const trimmed = trimTrailingCR(line);
        if (isBlank(trimmed) or (trimmed.len > 0 and trimmed[0] == '#')) continue;

        counts.checked += 1;

        const eq_raw = std.mem.indexOfScalar(u8, line, '=') orelse {
            try stderr.print("LINE_ERROR_NO_EQUALS: {s}:{d}\n", .{ path, lineno });
            counts.errors += 1;
            continue;
        };

        const raw_key = line[0..eq_raw];
        const raw_value = line[eq_raw + 1 ..];

        if (action == .normalize) {
            try stdout.print("{s}={s}\n", .{ raw_key, raw_value });
            continue;
        }

        const work = if (native) line else trimmed;
        const eq = std.mem.indexOfScalar(u8, work, '=') orelse {
            try stderr.print("LINE_ERROR_NO_EQUALS: {s}:{d}\n", .{ path, lineno });
            counts.errors += 1;
            continue;
        };

        const key = work[0..eq];
        const value = work[eq + 1 ..];

        if (native) {
            if (key.len == 0) {
                try stderr.print("LINE_ERROR_EMPTY_KEY: {s}:{d}\n", .{ path, lineno });
                counts.errors += 1;
                continue;
            }
            try handleRecord(allocator, action, true, key, raw_value, value, path, lineno, env, stderr, stdout, counts);
            continue;
        }

        if (key.len > 0 and isWhitespace(key[0])) {
            try stderr.print("LINE_ERROR_KEY_LEADING_WHITESPACE: {s}:{d}\n", .{ path, lineno });
            counts.errors += 1;
            continue;
        }
        if (key.len > 0 and isWhitespace(key[key.len - 1])) {
            try stderr.print("LINE_ERROR_KEY_TRAILING_WHITESPACE: {s}:{d}\n", .{ path, lineno });
            counts.errors += 1;
            continue;
        }
        if (value.len > 0 and isWhitespace(value[0])) {
            try stderr.print("LINE_ERROR_VALUE_LEADING_WHITESPACE: {s}:{d}\n", .{ path, lineno });
            counts.errors += 1;
            continue;
        }
        if (key.len == 0) {
            try stderr.print("LINE_ERROR_EMPTY_KEY: {s}:{d}\n", .{ path, lineno });
            counts.errors += 1;
            continue;
        }
        if (!validShellKey(key)) {
            try stderr.print("LINE_ERROR_KEY_INVALID: {s}:{d}\n", .{ path, lineno });
            counts.errors += 1;
            continue;
        }

        var out_value = value;
        if (value.len > 0) {
            const c = value[0];
            if (c == '"' or c == '\'') {
                const rest = value[1..];
                const close_pos = std.mem.indexOfScalar(u8, rest, c) orelse {
                    const code = if (c == '"') "LINE_ERROR_DOUBLE_QUOTE_UNTERMINATED" else "LINE_ERROR_SINGLE_QUOTE_UNTERMINATED";
                    try stderr.print("{s}: {s}:{d}\n", .{ code, path, lineno });
                    counts.errors += 1;
                    continue;
                };
                if (close_pos + 1 < rest.len) {
                    try stderr.print("LINE_ERROR_TRAILING_CONTENT: {s}:{d}\n", .{ path, lineno });
                    counts.errors += 1;
                    continue;
                }
                out_value = rest[0..close_pos];
            } else if (containsBadShellValueByte(value)) {
                try stderr.print("LINE_ERROR_VALUE_INVALID_CHAR: {s}:{d}\n", .{ path, lineno });
                counts.errors += 1;
                continue;
            }
        }

        try handleRecord(allocator, action, false, key, raw_value, out_value, path, lineno, env, stderr, stdout, counts);
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var out_buf: [65536]u8 = undefined;
    var out_writer: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const stdout = &out_writer.interface;

    var err_buf: [4096]u8 = undefined;
    var err_writer: Io.File.Writer = .init(.stderr(), io, &err_buf);
    const stderr = &err_writer.interface;

    const format = init.environ_map.get("ENVFILE_FORMAT") orelse "shell";
    const native = std.mem.eql(u8, format, "native");
    const action = parseAction(stderr, init.environ_map.get("ENVFILE_ACTION") orelse "validate");
    const bom = parseBom(stderr, format, init.environ_map.get("ENVFILE_BOM"));
    const crlf = init.environ_map.get("ENVFILE_CRLF") orelse "ignore";
    const nul = init.environ_map.get("ENVFILE_NUL") orelse "reject";
    const cont = init.environ_map.get("ENVFILE_BACKSLASH_CONTINUATION") orelse "ignore";

    if (native and bom != .literal) {
        var msg_buf: [256]u8 = undefined;
        const b = switch (bom) {
            .literal => "literal",
            .strip => "strip",
            .reject => "reject",
        };
        const msg = std.fmt.bufPrint(&msg_buf, "format=native ENVFILE_BOM={s}", .{b}) catch "format=native ENVFILE_BOM=<invalid>";
        fatal(stderr, "FATAL_ERROR_UNSUPPORTED", msg);
    }

    var env_store = EnvStore.init(arena);
    if (action == .delta or action == .apply) try env_store.seedFromProcess(init.environ_map);

    const args = try init.minimal.args.toSlice(arena);
    const files = if (args.len > 1) args[1..] else &[_][]const u8{"-"};

    var counts = Counts{};
    for (files) |path| {
        try processOneFile(arena, io, path, action, native, bom, crlf, nul, cont, &env_store, stdout, stderr, &counts);
    }

    if (action == .apply) try env_store.emitSorted(stdout);

    try stderr.print("{d} checked, {d} errors\n", .{ counts.checked, counts.errors });
    stdout.flush() catch {};
    stderr.flush() catch {};

    if (counts.errors > 0) std.process.exit(1);
}
