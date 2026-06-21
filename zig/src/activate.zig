//! Caveman/Ponytail SessionStart activation hook — Zig 0.16.
//!
//! Port of hooks/ponytail-activate.js. Runs once per session start:
//!   1. Resolve the default mode (env → config.json → "full").
//!   2. `off` mode → clear the flag, emit the host's "off" output, exit 0.
//!   3. Otherwise write the flag (symlink-safe) and emit the ponytail ruleset —
//!      Claude Code injects SessionStart hook stdout as hidden system context.
//!   4. If settings.json has no `statusLine`, append a setup nudge.
//!
//! Output now flows through `common.writeHookOutput`, which honors the Codex /
//! Copilot host envelopes (systemMessage / additionalContext JSON) just like
//! hooks/ponytail-runtime.js. Plain Claude Code still gets the raw context.
//!
//! The ruleset comes from the ponytail SKILL.md embedded at comptime (wired in
//! build.zig as the `skill_md` import) and mode-filtered by
//! `common.getInstructions` — the formalized port of
//! hooks/ponytail-instructions.js getPonytailInstructions, shared with the rest
//! of the binaries. The JS reads the SKILL from disk at runtime; embedding
//! removes that dependency and keeps the binary self-contained.
//!
//! Silent-fails on filesystem errors — never blocks session start.

const std = @import("std");
const common = @import("common.zig");
const c = common.c;

const TOOL = common.TOOL;
const TOOL_UPPER = common.TOOL_UPPER;
const SKILL_MD = @embedFile("skill_md");

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

    const mode = common.getDefaultMode(gpa) catch return; // silent-fail on OOM
    defer gpa.free(mode);

    const flag = common.flagPath(gpa) catch return; // silent-fail: no HOME etc.
    defer gpa.free(flag);

    // "off" mode — skip activation entirely; clear the flag, emit the host's
    // off-output. Plain host prints "OK"; Codex/Copilot suppress it (the JS
    // passes '' for Codex; Copilot emits {} for non-context output anyway).
    if (std.mem.eql(u8, mode, "off")) {
        common.clearFlag(flag);
        const off_ctx = if (common.detectHost() == .codex) "" else "OK";
        common.writeHookOutput(gpa, "SessionStart", "off", off_ctx);
        return;
    }

    // 1. Write flag file (best-effort; symlink-safe).
    common.safeWriteFlag(gpa, flag, mode) catch {};

    // 2. Build the ruleset for the active intensity (mode-filtered SKILL body).
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(gpa);
    const instructions = common.getInstructions(gpa, SKILL_MD, mode) catch {
        // If instruction build fails, still emit the bare header so the model
        // knows the mode is active (silent-fail contract: never crash).
        common.writeHookOutput(gpa, "SessionStart", mode, TOOL_UPPER);
        return;
    };
    defer gpa.free(instructions);
    output.appendSlice(gpa, instructions) catch return;

    // 3. Statusline-config nudge — skipped under Codex (matches the JS, which
    //    guards the whole statusline block with `if (!isCodex)`).
    if (common.detectHost() != .codex) blk: {
        const cdir = common.claudeDir(gpa) catch break :blk;
        defer gpa.free(cdir);
        const settings_path = std.fs.path.join(gpa, &.{ cdir, "settings.json" }) catch break :blk;
        defer gpa.free(settings_path);

        if (!hasStatusline(gpa, settings_path)) {
            // Leading sentence is byte-identical to the JS nudge
            // (hooks/ponytail-activate.js). The JS then splices an ABSOLUTE
            // script path resolved at runtime; a self-contained comptime binary
            // has no install-dir knowledge, so it names the installed statusline
            // binary/script instead. The nudge is advisory text for the model,
            // not an executed command — the one intentional divergence.
            const nudge = std.fmt.allocPrint(
                gpa,
                "\n\nSTATUSLINE SETUP NEEDED: The {s} plugin includes a statusline badge showing active mode " ++
                    "(e.g. [{s}], [{s}:ULTRA]). It is not configured yet. " ++
                    "To enable, add a \"statusLine\" command entry to ~/.claude/settings.json pointing at " ++
                    "the installed {s}-statusline binary (or {s}-statusline.sh). " ++
                    "Proactively offer to set this up for the user on first interaction.",
                .{ TOOL, TOOL_UPPER, TOOL_UPPER, TOOL, TOOL },
            ) catch break :blk;
            defer gpa.free(nudge);
            output.appendSlice(gpa, nudge) catch {};
        }
    }

    // 4. Emit through the host dispatch (plain = raw, Codex/Copilot = envelope).
    common.writeHookOutput(gpa, "SessionStart", mode, output.items);
}

// ── Tests ───────────────────────────────────────────────────────────────────
//
// The instruction-builder + host-dispatch logic now lives in common.zig and is
// tested there (filterSkillBodyForMode, getInstructions, buildHookOutputFor).
// These tests cover the activate-specific glue: SKILL_MD embeds the real body,
// and getInstructions over it produces the expected mode-keyed output.

test "getInstructions over embedded SKILL_MD: header + mode-filtered body" {
    const gpa = std.testing.allocator;
    const out = try common.getInstructions(gpa, SKILL_MD, "ultra");
    defer gpa.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, TOOL_UPPER ++ " MODE ACTIVE — level: ultra\n\n"));
    // ultra row kept, other intensity rows dropped (real SKILL.md intensity table).
    try std.testing.expect(std.mem.indexOf(u8, out, "YAGNI extremist") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "User picks.") == null); // lite row
    // A non-mode rule bullet survives regardless of mode.
    try std.testing.expect(std.mem.indexOf(u8, out, "No unrequested abstractions") != null);
}

test "getInstructions over embedded SKILL_MD: review stub, no body" {
    const gpa = std.testing.allocator;
    const out = try common.getInstructions(gpa, SKILL_MD, "review");
    defer gpa.free(out);
    const expected = TOOL_UPPER ++ " MODE ACTIVE — level: review. Behavior defined by /" ++ TOOL ++ "-review skill.";
    try std.testing.expectEqualStrings(expected, out);
}
