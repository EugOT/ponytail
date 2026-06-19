//! Caveman/Ponytail instructions CLI — Zig 0.16.
//!
//! One-shot ruleset printer for the host-mandated ESM/JS entry shims that cannot
//! themselves be Zig (opencode requires an ESM plugin module; pi requires a JS
//! extension module). Those shims keep only the host glue and exec THIS binary to
//! get the ruleset body, so the instruction-building logic lives in Zig — the
//! same `common.getInstructions` the SessionStart activate binary, the
//! UserPromptSubmit hook, and the MCP server already share.
//!
//! Usage (mode passed via env var, NOT argv — keeps this binary on the same
//! libc-C-ABI path as the other hooks, which read getenv but never touch
//! std.os.argv / std.Io):
//!
//!   <TOOL>_INSTRUCTIONS_MODE=<mode> <tool>-instructions
//!
//! The shims set <TOOL>_INSTRUCTIONS_MODE (e.g. PONYTAIL_INSTRUCTIONS_MODE) to
//! the session's active mode before spawning. Env-var passing is a clean,
//! well-defined subprocess contract and avoids the std.process.Args /
//! std.Io.Threaded machinery the rest of these libc-only binaries deliberately
//! skip.
//!
//! Behavior — an EXACT match for hooks/ponytail-instructions.js
//! getPonytailInstructions(mode), so a shim that execs this is byte-equivalent to
//! a shim that `require`d the JS builder:
//!   - env mode present   → emit getInstructions(SKILL_MD, mode) for that mode.
//!   - env mode absent     → resolve the default (env → config.json → "full") via
//!                          common.getDefaultMode, exactly like the JS shims call
//!                          getPonytailInstructions(getDefaultMode()).
//!   - "off"              → the JS shims treat "off" as "inject nothing" at their
//!                          own layer (the opencode transform returns early; pi's
//!                          before_agent_start returns early). So when asked for
//!                          "off" we print NOTHING and exit 0 — the shim that
//!                          execs us gets empty stdout and injects nothing, which
//!                          is the same observable behavior.
//!   - "review" / unknown → getInstructions already mirrors the JS
//!                          (review → one-line stub; unknown → DEFAULT_MODE body).
//!
//! The ruleset is built over the ponytail SKILL.md embedded at comptime (wired in
//! build.zig as the `skill_md` import, exactly like activate.zig / mcp.zig), so
//! the binary is self-contained and never reads the SKILL from disk at runtime.
//!
//! Raw stdout, no host envelope: the shims wrap the body in the host's own system
//! prompt structure (opencode output.system.push / pi systemPrompt concat); this
//! binary only owns the ruleset TEXT, matching what getPonytailInstructions
//! returned to those shims before.

const std = @import("std");
const common = @import("common.zig");
const c = common.c;

const SKILL_MD = @embedFile("skill_md");

/// The env var the shims set to request a specific mode: "<TOOL>_INSTRUCTIONS_MODE"
/// (e.g. "PONYTAIL_INSTRUCTIONS_MODE"). Built at comptime from the tool identity.
const MODE_ENV: [:0]const u8 = blk: {
    var out: [common.TOOL.len + "_INSTRUCTIONS_MODE".len:0]u8 = undefined;
    for (common.TOOL, 0..) |ch, i| out[i] = std.ascii.toUpper(ch);
    const suffix = "_INSTRUCTIONS_MODE";
    for (suffix, 0..) |ch, i| out[common.TOOL.len + i] = ch;
    out[out.len] = 0;
    const final = out;
    break :blk &final;
};

/// Read the requested mode from $<TOOL>_INSTRUCTIONS_MODE, or null when absent /
/// empty. Borrowed from the environment block (valid for the process lifetime).
fn modeFromEnv() ?[]const u8 {
    const v = common.getenv(MODE_ENV.ptr) orelse return null;
    if (v.len == 0) return null;
    return v;
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // Resolve the requested mode: explicit env override, else the configured
    // default. getDefaultMode returns an owned copy; an env mode is borrowed.
    var owned_default: ?[]u8 = null;
    defer if (owned_default) |d| gpa.free(d);

    const mode: []const u8 = if (modeFromEnv()) |env_mode| env_mode else blk: {
        const d = common.getDefaultMode(gpa);
        owned_default = d;
        break :blk d;
    };

    // "off" → emit nothing. The JS shims short-circuit injection on "off"; an
    // empty stdout makes the exec-shim do the same (push nothing / concat nothing).
    if (std.mem.eql(u8, std.mem.trim(u8, mode, " \t\r\n"), "off")) return;

    // Build the ruleset exactly like getPonytailInstructions. On a build failure
    // (allocation), stay silent rather than emitting a partial body — the shim
    // then injects nothing, never a truncated ruleset.
    const instructions = common.getInstructions(gpa, SKILL_MD, mode) catch return;
    defer gpa.free(instructions);
    common.writeStdout(instructions);
}

// ── Tests ───────────────────────────────────────────────────────────────────
//
// getInstructions / filterSkillBodyForMode are tested in common.zig. The
// instructions binary is glue (env-var mode read + the "off" short-circuit), so
// the tests here pin the three seams this file owns: the MODE_ENV name is the
// tool-uppercased var the shims set, getInstructions over the embedded SKILL_MD
// produces the mode-keyed header/body, and the "off" trim predicate matches what
// main short-circuits on.

const TOOL_UPPER = common.TOOL_UPPER;

test "MODE_ENV is the tool-uppercased instructions var the shims set" {
    try std.testing.expectEqualStrings(TOOL_UPPER ++ "_INSTRUCTIONS_MODE", MODE_ENV);
}

test "getInstructions over embedded SKILL_MD: header + mode-filtered body" {
    const gpa = std.testing.allocator;
    const out = try common.getInstructions(gpa, SKILL_MD, "ultra");
    defer gpa.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, TOOL_UPPER ++ " MODE ACTIVE — level: ultra\n\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "YAGNI extremist") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "User picks.") == null); // lite row dropped
}

test "off short-circuit predicate matches main (trimmed equality)" {
    // main emits nothing iff the trimmed mode == "off"; assert the predicate
    // matches both the bare and whitespace-padded forms a shim might pass.
    try std.testing.expect(std.mem.eql(u8, std.mem.trim(u8, "off", " \t\r\n"), "off"));
    try std.testing.expect(std.mem.eql(u8, std.mem.trim(u8, "  off \n", " \t\r\n"), "off"));
    try std.testing.expect(!std.mem.eql(u8, std.mem.trim(u8, "full", " \t\r\n"), "off"));
}
