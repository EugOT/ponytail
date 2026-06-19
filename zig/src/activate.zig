//! Caveman/Ponytail SessionStart activation hook — Zig 0.16.
//!
//! Port of hooks/ponytail-activate.js. Runs once per session start:
//!   1. Resolve the default mode (env → config.json → "full").
//!   2. `off` mode → clear the flag, print "OK", exit 0 (no rules emitted).
//!   3. Otherwise write the flag (symlink-safe) and emit the ponytail ruleset
//!      as stdout — Claude Code injects SessionStart hook stdout as hidden
//!      system context.
//!   4. If settings.json has no `statusLine`, append a setup nudge.
//!
//! Codex/Copilot host wrapping (writeHookOutput's systemMessage / JSON shapes)
//! is NOT handled here — those hosts run the JS bundle. This binary targets the
//! plain Claude Code SessionStart contract (raw stdout = context), the common
//! case the statusline + flag path also assume.
//!
//! The ruleset comes from the ponytail SKILL.md embedded at comptime (wired in
//! build.zig as the `skill_md` import). The JS reads it from disk at runtime;
//! embedding removes the runtime path dependency and keeps the binary
//! self-contained. The mode filter mirrors filterSkillBodyForMode.
//!
//! Silent-fails on filesystem errors — never blocks session start.

const std = @import("std");
const common = @import("common.zig");
const c = common.c;

const TOOL = common.TOOL;
const SKILL_MD = @embedFile("skill_md");

// Upper-cased tool for the badge text in the nudge ("PONYTAIL").
const TOOL_UPPER = blk: {
    var out: [TOOL.len]u8 = undefined;
    for (TOOL, 0..) |ch, i| out[i] = std.ascii.toUpper(ch);
    const final = out;
    break :blk &final;
};

const INDEPENDENT_MODES = [_][]const u8{"review"};

fn isIndependent(mode: []const u8) bool {
    for (INDEPENDENT_MODES) |m| if (std.mem.eql(u8, m, mode)) return true;
    return false;
}

/// Strip a leading YAML frontmatter block (`---\n...\n---\n`). Mirrors the JS
/// `replace(/^---[\s\S]*?---\s*/, '')`.
fn stripFrontmatter(body: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, body, "---")) return body;
    // Find the closing "---" on its own logical position after the opener.
    // JS regex is non-greedy: first "---" after the opening one.
    const search_from: usize = 3;
    while (std.mem.indexOfPos(u8, body, search_from, "---")) |idx| {
        var end = idx + 3;
        // Consume trailing whitespace (\s* in the regex).
        while (end < body.len and std.ascii.isWhitespace(body[end])) end += 1;
        return body[end..];
    } else return body;
}

/// Is `label` (already trimmed) one of the intensity modes lite/full/ultra?
fn labelMode(label: []const u8) ?[]const u8 {
    var buf: [16]u8 = undefined;
    const t = std.mem.trim(u8, label, " \t");
    if (t.len == 0 or t.len > buf.len) return null;
    for (t, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    const lowered = buf[0..t.len];
    for (common.VALID_MODES) |m| {
        if (std.mem.eql(u8, m, lowered)) return m;
    }
    return null;
}

/// Extract a `**Label**` from a markdown table row `| **Label** | ...`.
/// Returns the inner label slice or null.
fn tableRowLabel(line: []const u8) ?[]const u8 {
    const t = std.mem.trimStart(u8, line, " \t");
    if (!std.mem.startsWith(u8, t, "|")) return null;
    const after_pipe = std.mem.trimStart(u8, t[1..], " \t");
    if (!std.mem.startsWith(u8, after_pipe, "**")) return null;
    const inner = after_pipe[2..];
    const close = std.mem.indexOf(u8, inner, "**") orelse return null;
    return inner[0..close];
}

/// Extract the label from an example bullet `- label: ...`. Returns null if no
/// colon, or if the part before the colon is empty.
fn bulletLabel(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "-")) return null;
    const after = std.mem.trimStart(u8, line[1..], " \t");
    const colon = std.mem.indexOfScalar(u8, after, ':') orelse return null;
    if (colon == 0) return null;
    return after[0..colon];
}

/// Filter the SKILL body to the active intensity mode. Keeps every line except
/// mode-keyed table rows / example bullets for OTHER modes. Mirrors
/// hooks/ponytail-instructions.js filterSkillBodyForMode.
fn filterSkillBodyForMode(gpa: std.mem.Allocator, body: []const u8, mode: []const u8) ![]u8 {
    const without_fm = stripFrontmatter(body);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var first = true;
    var it = std.mem.splitScalar(u8, without_fm, '\n');
    while (it.next()) |raw_line| {
        // Normalize CRLF: drop a trailing '\r' for label matching, but the JS
        // split is on /\r?\n/ so the '\r' is already gone from the line.
        const line = std.mem.trimEnd(u8, raw_line, "\r");

        var keep = true;
        if (tableRowLabel(line)) |lbl| {
            if (labelMode(lbl)) |lm| keep = std.mem.eql(u8, lm, mode);
        } else if (bulletLabel(line)) |lbl| {
            if (labelMode(lbl)) |lm| keep = std.mem.eql(u8, lm, mode);
        }

        if (keep) {
            if (!first) try out.append(gpa, '\n');
            try out.appendSlice(gpa, line);
            first = false;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Build the full instruction string for `mode`. Mirrors
/// hooks/ponytail-instructions.js getPonytailInstructions: a header line, then
/// the filtered SKILL body. Independent modes (review) get the one-line stub.
fn getInstructions(gpa: std.mem.Allocator, mode: []const u8) ![]u8 {
    if (isIndependent(mode)) {
        return std.fmt.allocPrint(
            gpa,
            "{s} MODE ACTIVE — level: {s}. Behavior defined by /{s}-{s} skill.",
            .{ TOOL_UPPER, mode, TOOL, mode },
        );
    }

    const filtered = try filterSkillBodyForMode(gpa, SKILL_MD, mode);
    defer gpa.free(filtered);
    return std.fmt.allocPrint(
        gpa,
        "{s} MODE ACTIVE — level: {s}\n\n{s}",
        .{ TOOL_UPPER, mode, filtered },
    );
}

/// Does settings.json declare a `statusLine` key? Tolerates a UTF-8 BOM, like
/// the JS. Returns false on any read/parse failure (→ nudge offered).
fn hasStatusline(gpa: std.mem.Allocator, settings_path: []const u8) bool {
    const raw = readSmallFile(gpa, settings_path) orelse return false;
    defer gpa.free(raw);
    var slice: []const u8 = raw;
    // Strip a UTF-8 BOM some Windows editors prepend.
    if (slice.len >= 3 and slice[0] == 0xEF and slice[1] == 0xBB and slice[2] == 0xBF) {
        slice = slice[3..];
    }
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, slice, .{}) catch return false;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return false,
    };
    return obj.get("statusLine") != null;
}

fn readSmallFile(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const pz = common.toZ(&pbuf, path) catch return null;
    const flags: c.O = .{ .ACCMODE = .RDONLY };
    const fd = c.open(pz, flags, @as(c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = common.close(fd);

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) {
            list.deinit(gpa);
            return null;
        }
        if (n == 0) break;
        list.appendSlice(gpa, buf[0..@intCast(n)]) catch {
            list.deinit(gpa);
            return null;
        };
    }
    return list.toOwnedSlice(gpa) catch null;
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const mode = common.getDefaultMode(gpa);
    defer gpa.free(mode);

    const flag = common.flagPath(gpa) catch return; // silent-fail: no HOME etc.
    defer gpa.free(flag);

    // "off" mode — skip activation entirely; clear the flag, print "OK", exit.
    if (std.mem.eql(u8, mode, "off")) {
        common.clearFlag(flag);
        common.writeStdout("OK");
        return;
    }

    // 1. Write flag file (best-effort; symlink-safe).
    common.safeWriteFlag(gpa, flag, mode) catch {};

    // 2. Build the ruleset for the active intensity.
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(gpa);
    const instructions = getInstructions(gpa, mode) catch {
        // If instruction build fails, still emit the bare header so the model
        // knows the mode is active (silent-fail contract: never crash).
        common.writeStdout(TOOL_UPPER);
        return;
    };
    defer gpa.free(instructions);
    output.appendSlice(gpa, instructions) catch return;

    // 3. Statusline-config nudge.
    const cdir = common.claudeDir(gpa) catch {
        common.writeStdout(output.items);
        return;
    };
    defer gpa.free(cdir);
    const settings_path = std.fs.path.join(gpa, &.{ cdir, "settings.json" }) catch {
        common.writeStdout(output.items);
        return;
    };
    defer gpa.free(settings_path);

    if (!hasStatusline(gpa, settings_path)) {
        // The leading sentence is byte-identical to the JS nudge
        // (hooks/ponytail-activate.js). The JS then splices an ABSOLUTE script
        // path it resolves at runtime; a self-contained comptime binary has no
        // install-dir knowledge, so it points at the installed statusline
        // binary/script by name instead. The nudge is advisory text for the
        // model, not an executed command — this is the one intentional
        // divergence from the JS activate output (line 86 of the emitted text).
        const nudge = std.fmt.allocPrint(
            gpa,
            "\n\nSTATUSLINE SETUP NEEDED: The {s} plugin includes a statusline badge showing active mode " ++
                "(e.g. [{s}], [{s}:ULTRA]). It is not configured yet. " ++
                "To enable, add a \"statusLine\" command entry to ~/.claude/settings.json pointing at " ++
                "the installed {s}-statusline binary (or {s}-statusline.sh). " ++
                "Proactively offer to set this up for the user on first interaction.",
            .{ TOOL, TOOL_UPPER, TOOL_UPPER, TOOL, TOOL },
        ) catch {
            common.writeStdout(output.items);
            return;
        };
        defer gpa.free(nudge);
        output.appendSlice(gpa, nudge) catch {};
    }

    common.writeStdout(output.items);
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "stripFrontmatter removes leading YAML block" {
    const body = "---\nname: x\n---\n# Heading\nbody";
    try std.testing.expectEqualStrings("# Heading\nbody", stripFrontmatter(body));
    // No frontmatter → unchanged.
    try std.testing.expectEqualStrings("# Heading", stripFrontmatter("# Heading"));
}

test "labelMode recognizes only intensity modes" {
    try std.testing.expectEqualStrings("lite", labelMode("lite").?);
    try std.testing.expectEqualStrings("full", labelMode(" Full ").?);
    try std.testing.expectEqualStrings("ultra", labelMode("ULTRA").?);
    try std.testing.expect(labelMode("review") == null); // not an intensity row
    try std.testing.expect(labelMode("No unrequested abstractions") == null);
}

test "tableRowLabel and bulletLabel extraction" {
    try std.testing.expectEqualStrings("lite", tableRowLabel("| **lite** | text |").?);
    try std.testing.expect(tableRowLabel("plain line") == null);
    try std.testing.expectEqualStrings("lite", bulletLabel("- lite: example").?);
    try std.testing.expectEqualStrings(
        "No unrequested abstractions",
        bulletLabel("- No unrequested abstractions: no interface").?,
    );
    try std.testing.expect(bulletLabel("- no colon here") == null);
}

test "filterSkillBodyForMode keeps active-mode rows, drops others, keeps non-mode bullets" {
    const gpa = std.testing.allocator;
    const body =
        "# Title\n" ++
        "| **lite** | lite row |\n" ++
        "| **full** | full row |\n" ++
        "| **ultra** | ultra row |\n" ++
        "- lite: lite example\n" ++
        "- full: full example\n" ++
        "- No unrequested abstractions: keep me\n";

    const out = try filterSkillBodyForMode(gpa, body, "full");
    defer gpa.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "full row") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "full example") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "lite row") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ultra row") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "lite example") == null);
    // Non-mode bullet is a real rule — must survive.
    try std.testing.expect(std.mem.indexOf(u8, out, "keep me") != null);
    // Title always survives.
    try std.testing.expect(std.mem.indexOf(u8, out, "# Title") != null);
}

test "getInstructions header for intensity mode" {
    const gpa = std.testing.allocator;
    const out = try getInstructions(gpa, "ultra");
    defer gpa.free(out);
    // Header line present.
    const expected_prefix = TOOL_UPPER ++ " MODE ACTIVE — level: ultra\n\n";
    try std.testing.expect(std.mem.startsWith(u8, out, expected_prefix));
}

test "getInstructions independent (review) mode is the stub" {
    const gpa = std.testing.allocator;
    const out = try getInstructions(gpa, "review");
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Behavior defined by /" ++ TOOL ++ "-review skill") != null);
    // The stub does NOT include the full SKILL body.
    try std.testing.expect(std.mem.indexOf(u8, out, "The ladder") == null);
}
