//! Caveman/Ponytail statusline badge — Zig 0.16.
//!
//! Port of hooks/ponytail-statusline.sh (and the .ps1 counterpart). Reads the
//! flag file at $CLAUDE_CONFIG_DIR/.<tool>-active, whitelist-validates the mode,
//! and prints a colored "[PONYTAIL]" / "[PONYTAIL:MODE]" badge.
//!
//! Cross-platform: no shell. Opens the flag with O_NOFOLLOW so a symlink
//! pre-planted at the predictable flag path cannot redirect the read off to an
//! arbitrary file whose bytes would then be echoed to the terminal. The mode is
//! whitelisted against {off,lite,full,ultra,review} before rendering, and any
//! control bytes are stripped — a clobbered flag cannot smuggle escape
//! sequences or control characters onto the statusline.
//!
//! ponytail's statusline has NO lifetime-savings suffix (that is a caveman
//! feature); this mirrors hooks/ponytail-statusline.sh exactly, which prints the
//! badge and nothing else.

const std = @import("std");
const common = @import("common.zig");
const c = common.c;

const TOOL_UPPER = blk: {
    var out: [common.TOOL.len]u8 = undefined;
    for (common.TOOL, 0..) |ch, i| out[i] = std.ascii.toUpper(ch);
    const final = out;
    break :blk &final;
};

const COLOR_ON = "\x1b[38;5;108m";
const COLOR_OFF = "\x1b[0m";

/// Tri-state result of reading the flag, mirroring the sh control flow:
///   .missing — no flag file (or unreadable / symlinked) → print NOTHING and
///              exit 0, like `[ -f "$flag" ] || exit 0`.
///   .blank   — flag present but the mode is empty or not whitelisted → render
///              the bare `[PONYTAIL]` badge, like the sh `-z "$mode"` branch.
///   .mode    — a whitelisted non-full mode (`len` bytes in the out buffer).
const ReadResult = union(enum) {
    missing,
    blank,
    mode: usize, // byte length of the validated mode written to `out`
};

/// Read the flag's first line via O_NOFOLLOW open + raw read, whitelist the
/// mode, strip control bytes. `out` must be >= 16 bytes.
fn readMode(flag: []const u8, out: []u8) ReadResult {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const pz = common.toZ(&pbuf, flag) catch return .missing;

    // O_RDONLY | O_NOFOLLOW: refuse to follow a symlink at the flag path. A
    // missing file or a symlinked flag both map to .missing — print nothing.
    const flags: c.O = .{ .ACCMODE = .RDONLY, .NOFOLLOW = true };
    const fd = c.open(pz, flags, @as(c.mode_t, 0));
    if (fd < 0) return .missing;
    defer _ = common.close(fd);

    var buf: [256]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    // File present but empty/unreadable → blank badge (the file existed).
    if (n <= 0) return .blank;
    const raw = buf[0..@intCast(n)];

    // head -n1: first line only.
    const line_end = std.mem.indexOfScalar(u8, raw, '\n') orelse raw.len;
    const line0 = raw[0..line_end];

    // tr -d '[:space:]': strip ALL whitespace/control bytes, not just ends.
    // This also drops any smuggled control characters.
    var len: usize = 0;
    for (line0) |ch| {
        if (ch <= 0x20 or ch == 0x7f) continue; // control + space
        if (len >= out.len) return .blank; // too long → not whitelisted → blank
        out[len] = std.ascii.toLower(ch);
        len += 1;
    }
    const mode = out[0..len];

    // Whitelist: off|lite|full|ultra|review. Anything else → blank (the flag
    // existed, so we still render the bare badge, matching the sh blank branch).
    if (!common.isStatuslineMode(mode)) return .blank;
    return .{ .mode = len };
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const flag = common.flagPath(gpa) catch return; // no HOME → print nothing (sh exits 0)
    defer gpa.free(flag);

    var mode_buf: [16]u8 = undefined;
    const mode: []const u8 = switch (readMode(flag, &mode_buf)) {
        // No flag file → print nothing, exit 0 (sh `[ -f "$flag" ] || exit 0`).
        .missing => return,
        // Present but empty/non-whitelisted → bare badge (sh `-z "$mode"`).
        .blank => "",
        .mode => |len| mode_buf[0..len],
    };

    // Empty (blanked) or "full" → bare badge. Mirrors the sh `-z` / `= full`.
    if (mode.len == 0 or std.mem.eql(u8, mode, "full")) {
        common.writeStdout(COLOR_ON ++ "[" ++ TOOL_UPPER ++ "]" ++ COLOR_OFF);
        return;
    }

    // [PONYTAIL:MODE] with MODE uppercased.
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    line.appendSlice(gpa, COLOR_ON ++ "[" ++ TOOL_UPPER ++ ":") catch return;
    for (mode) |ch| line.append(gpa, std.ascii.toUpper(ch)) catch return;
    line.appendSlice(gpa, "]" ++ COLOR_OFF) catch return;
    common.writeStdout(line.items);
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// Render the badge for a pre-validated mode slice (the pure half of main),
/// so tests can assert output without touching the filesystem.
fn renderBadge(gpa: std.mem.Allocator, mode: []const u8) ![]u8 {
    if (mode.len == 0 or std.mem.eql(u8, mode, "full")) {
        return gpa.dupe(u8, COLOR_ON ++ "[" ++ TOOL_UPPER ++ "]" ++ COLOR_OFF);
    }
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(gpa);
    try line.appendSlice(gpa, COLOR_ON ++ "[" ++ TOOL_UPPER ++ ":");
    for (mode) |ch| try line.append(gpa, std.ascii.toUpper(ch));
    try line.appendSlice(gpa, "]" ++ COLOR_OFF);
    return line.toOwnedSlice(gpa);
}

fn makeTmpDir(gpa: std.mem.Allocator) ![]u8 {
    const base = common.getenv("TMPDIR") orelse "/tmp";
    const dir = try std.fmt.allocPrint(gpa, "{s}/zigsltest.{d}", .{ base, c.getpid() });
    var dbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dz = try common.toZ(&dbuf, dir);
    _ = c.mkdir(dz, 0o700);
    return dir;
}

fn writeFile(path: []const u8, content: []const u8) !void {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const pz = try common.toZ(&pbuf, path);
    const fl: c.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    const fd = c.open(pz, fl, @as(c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = common.close(fd);
    _ = c.write(fd, content.ptr, content.len);
}

test "renderBadge: full and empty give bare badge" {
    const gpa = std.testing.allocator;
    const bare = COLOR_ON ++ "[" ++ TOOL_UPPER ++ "]" ++ COLOR_OFF;

    const a = try renderBadge(gpa, "full");
    defer gpa.free(a);
    try std.testing.expectEqualStrings(bare, a);

    const b = try renderBadge(gpa, "");
    defer gpa.free(b);
    try std.testing.expectEqualStrings(bare, b);
}

test "renderBadge: non-full mode is uppercased in suffix" {
    const gpa = std.testing.allocator;
    const out = try renderBadge(gpa, "ultra");
    defer gpa.free(out);
    try std.testing.expectEqualStrings(COLOR_ON ++ "[" ++ TOOL_UPPER ++ ":ULTRA]" ++ COLOR_OFF, out);
}

/// Test helper: assert readMode yields a `.mode` of exactly `expect`.
fn expectMode(flag: []const u8, expect: []const u8) !void {
    var buf: [16]u8 = undefined;
    switch (readMode(flag, &buf)) {
        .mode => |len| try std.testing.expectEqualStrings(expect, buf[0..len]),
        else => return error.TestExpectedMode,
    }
}

test "readMode whitelists valid modes" {
    const gpa = std.testing.allocator;
    const dir = try makeTmpDir(gpa);
    defer gpa.free(dir);
    const flag = try std.fs.path.join(gpa, &.{ dir, ".active" });
    defer gpa.free(flag);

    try writeFile(flag, "ultra\n");
    try expectMode(flag, "ultra");

    // review is whitelisted.
    try writeFile(flag, "review");
    try expectMode(flag, "review");

    var fb: [std.fs.max_path_bytes]u8 = undefined;
    _ = c.unlink(try common.toZ(&fb, flag));
}

test "readMode rejects junk and strips control bytes" {
    const gpa = std.testing.allocator;
    const dir = try makeTmpDir(gpa);
    defer gpa.free(dir);
    const flag = try std.fs.path.join(gpa, &.{ dir, ".active2" });
    defer gpa.free(flag);

    var buf: [16]u8 = undefined;

    // Garbage word → not whitelisted → .blank (file existed).
    try writeFile(flag, "rm -rf /\n");
    try std.testing.expect(readMode(flag, &buf) == .blank);

    // Smuggled escape sequence around a valid word: control bytes stripped, and
    // the embedded "[31m" makes the residue non-whitelisted → .blank.
    try writeFile(flag, "\x1b[31mfull\x1b[0m\n");
    try std.testing.expect(readMode(flag, &buf) == .blank);

    // Pure control bytes around a clean mode: stripping leaves "ultra" → kept.
    try writeFile(flag, "\x00ul\x07tra\x7f\n");
    try expectMode(flag, "ultra");

    // Missing file → .missing (sh `[ -f ] || exit 0`, distinct from blank).
    var fb: [std.fs.max_path_bytes]u8 = undefined;
    _ = c.unlink(try common.toZ(&fb, flag));
    try std.testing.expect(readMode(flag, &buf) == .missing);

    // Present but empty file → .blank (renders bare badge, not nothing).
    try writeFile(flag, "");
    try std.testing.expect(readMode(flag, &buf) == .blank);
    _ = c.unlink(try common.toZ(&fb, flag));
}

test "readMode refuses a symlinked flag (O_NOFOLLOW)" {
    const gpa = std.testing.allocator;
    const dir = try makeTmpDir(gpa);
    defer gpa.free(dir);

    const victim = try std.fs.path.join(gpa, &.{ dir, "victim" });
    defer gpa.free(victim);
    const flag = try std.fs.path.join(gpa, &.{ dir, ".active3" });
    defer gpa.free(flag);

    try writeFile(victim, "full\n"); // a valid-looking mode behind the link
    var vb: [std.fs.max_path_bytes]u8 = undefined;
    var fb: [std.fs.max_path_bytes]u8 = undefined;
    const vz = try common.toZ(&vb, victim);
    const fz = try common.toZ(&fb, flag);
    try std.testing.expect(c.symlink(vz, fz) == 0);

    var buf: [16]u8 = undefined;
    // O_NOFOLLOW open of the symlink fails → .missing, even though the target
    // is a valid mode. The badge prints nothing rather than echoing the link.
    try std.testing.expect(readMode(flag, &buf) == .missing);

    _ = c.unlink(fz);
    _ = c.unlink(vz);
}
