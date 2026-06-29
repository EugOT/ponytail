//! Ponytail pz adapter — Zig 0.16, pure-Zig, NO host shim.
//!
//! pz (github.com/EugOT/pz) loads skills by SCANNING the filesystem — it never
//! loads a host plugin module — so unlike pi/opencode the ponytail pz adapter is
//! just file emission a Zig binary does directly. This binary writes a first-class
//! ponytail skill pz can discover:
//!
//!   - Project: <root>/.pz/skills/ponytail/SKILL.md   (root = $PONYTAIL_REPO_ROOT or cwd)
//!   - Global:  $HOME/.pz/skills/ponytail/SKILL.md     (when $HOME resolves)
//!
//! These are the exact paths pz scans (pz/src/core/skill.zig: global
//! `~/.pz/skills/*/SKILL.md`, project `./.pz/skills/*/SKILL.md`).
//!
//! Frontmatter — matches pz's parser (pz/src/core/skill.zig parseKV/stripQuotes):
//! pz parses `name`, `description`, `disable_model_invocation`, `user_invocable`
//! as `key: value` (split on the first colon, trimmed). pz's stripQuotes strips
//! ONLY single quotes, never double — so the description is written UNQUOTED (a
//! single line; any inner colon is preserved because pz splits on the first colon
//! after the key). There is NO `always: true` on pz (that is a NullClaw concept):
//! a pz skill is model-invocable by default and offered when relevant, with
//! `user_invocable: true` so the user can `/ponytail`-invoke it too.
//!
//! Body — the mode-filtered ruleset from the embedded canonical SKILL.md, via
//! common.filterSkillBodyForMode for the resolved mode ($PONYTAIL_INSTRUCTIONS_MODE
//! override, else getDefaultMode → env/config/"full"). Same filter the
//! instructions binary / activate hook use, so the body never drifts from the
//! canonical skill.
//!
//! Writes go through common.safeWriteFlag (symlink-refuse + O_NOFOLLOW atomic
//! write) after a recursive symlink-safe mkdir of the parent chain — the same
//! safety the runtime flag writes get. Output dirs must sit under a trusted base
//! ($HOME / $TMPDIR / $CLAUDE_CONFIG_DIR); the normal cases (repo under $HOME, a
//! tmp test workspace, or $HOME itself for the global path) write cleanly.
//!
//! NB: always-on context on pz comes from a SEPARATE channel (AGENTS.md), not
//! this skill file — the SKILL.md alone is *discovery*. Emitting AGENTS.md is a
//! deliberate non-goal here (honest framing per the plan §3.1).

const std = @import("std");
const common = @import("common.zig");

const SKILL_MD = @embedFile("skill_md");

/// Single-line pz picker description (no double quotes — pz strips only single
/// quotes). Matches the short OpenClaw ponytail description.
const DESCRIPTION = "Lazy senior dev mode. Forces the simplest, shortest solution that works: YAGNI, stdlib first, no unrequested abstractions.";

const PzError = error{
    NoFrontmatterContract,
} || common.FlagError;

/// Resolve the mode for the emitted body: $PONYTAIL_INSTRUCTIONS_MODE override,
/// else the configured default. Returns an owned mode the caller frees.
fn resolveMode(gpa: std.mem.Allocator) common.FlagError![]u8 {
    if (common.getenv("PONYTAIL_INSTRUCTIONS_MODE")) |m| {
        if (m.len > 0) return gpa.dupe(u8, m);
    }
    return common.getDefaultMode(gpa);
}

/// Build the pz SKILL.md text for `mode`. Caller owns the returned slice.
/// Frontmatter (pz keys) + a single trailing newline after the closing fence +
/// the mode-filtered canonical body.
pub fn render(gpa: std.mem.Allocator, mode: []const u8) common.FlagError![]u8 {
    const body = try common.filterSkillBodyForMode(gpa, SKILL_MD, mode);
    defer gpa.free(body);
    return std.fmt.allocPrint(
        gpa,
        "---\nname: {s}\ndescription: {s}\nuser_invocable: true\n---\n{s}",
        .{ common.TOOL, DESCRIPTION, body },
    );
}

/// Emit `<dir>/.pz/skills/<tool>/SKILL.md` with `content`. Pre-creates the dir
/// chain (symlink-safe) then writes via safeWriteFlag. Reports the path.
fn emitInto(gpa: std.mem.Allocator, base_dir: []const u8, content: []const u8) common.FlagError!void {
    const out_path = try std.fs.path.join(gpa, &.{ base_dir, ".pz", "skills", common.TOOL, "SKILL.md" });
    defer gpa.free(out_path);
    if (std.fs.path.dirname(out_path)) |d| try common.makePathRecursive(gpa, d);
    try common.safeWriteFlag(gpa, out_path, content);
    common.writeStdout("wrote ");
    common.writeStdout(out_path);
    common.writeStdout("\n");
}

/// Resolve the project root: $PONYTAIL_REPO_ROOT or "." (cwd).
fn projectRoot() []const u8 {
    if (common.getenv("PONYTAIL_REPO_ROOT")) |r| {
        if (r.len > 0) return r;
    }
    return ".";
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // resolveMode/render return common.FlagError — not just OOM but invalid
    // mode/config/path failures too. Exiting 0 here would silently emit no skill
    // while reporting success; surface the error and fail loudly instead (the
    // same contract as emitInto's failures below).
    const mode = resolveMode(gpa) catch |err| {
        common.writeStdout("error: resolve-mode: ");
        common.writeStdout(@errorName(err));
        common.writeStdout("\n");
        std.process.exit(1);
    };
    defer gpa.free(mode);

    const content = render(gpa, mode) catch |err| {
        common.writeStdout("error: render: ");
        common.writeStdout(@errorName(err));
        common.writeStdout("\n");
        std.process.exit(1);
    };
    defer gpa.free(content);

    var failed = false;

    // Resolve to an absolute project root so the relative default ("." when
    // $PONYTAIL_REPO_ROOT is unset) isn't refused by safeWriteFlag's
    // ancestorUnsafe (which prefix-matches against the absolute trusted bases).
    const proj_root = common.absRoot(gpa, projectRoot()) catch |err| {
        common.writeStdout("error: resolve-root: ");
        common.writeStdout(@errorName(err));
        common.writeStdout("\n");
        std.process.exit(1);
    };
    defer gpa.free(proj_root);

    // Project skill (always — root resolves to cwd at minimum).
    emitInto(gpa, proj_root, content) catch |err| {
        common.writeStdout("error: project: ");
        common.writeStdout(@errorName(err));
        common.writeStdout("\n");
        failed = true;
    };

    // Global skill ($HOME/.pz/skills/...) when $HOME resolves. A missing $HOME is
    // not an error — the project skill alone is a valid install.
    if (common.getenv("HOME")) |home| {
        if (home.len > 0) {
            emitInto(gpa, home, content) catch |err| {
                common.writeStdout("error: global: ");
                common.writeStdout(@errorName(err));
                common.writeStdout("\n");
                failed = true;
            };
        }
    }

    if (failed) std.process.exit(1);
}

// ── Tests ───────────────────────────────────────────────────────────────────

const TOOL = common.TOOL;

test "render emits pz frontmatter: name, single-line unquoted description, user_invocable" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, "full");
    defer gpa.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "---\nname: " ++ TOOL ++ "\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "\ndescription: " ++ DESCRIPTION ++ "\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\nuser_invocable: true\n---\n") != null);
    // No double-quote wrapping (pz strips only single quotes).
    try std.testing.expect(std.mem.indexOf(u8, out, "description: \"") == null);
    // No always:true (pz has no such key — discovery, not force-injection).
    try std.testing.expect(std.mem.indexOf(u8, out, "always:") == null);
}

test "render body is mode-filtered (ultra drops lite rows)" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, "ultra");
    defer gpa.free(out);
    // The header line from getInstructions is NOT present — pz body is the raw
    // filtered SKILL body, not the "MODE ACTIVE" wrapper.
    try std.testing.expect(std.mem.indexOf(u8, out, "MODE ACTIVE") == null);
    // ultra-specific content kept; a lite-only example dropped (mirrors the
    // instructions binary's filtering, pinned in instructions.zig tests).
    try std.testing.expect(std.mem.indexOf(u8, out, "YAGNI extremist") != null);
}

test "DESCRIPTION obeys pz/openclaw single-line <160 contract" {
    try std.testing.expect(DESCRIPTION.len <= 160);
    try std.testing.expect(std.mem.indexOfScalar(u8, DESCRIPTION, '\n') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, DESCRIPTION, '"') == null);
}
