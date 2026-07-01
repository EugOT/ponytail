//! Ponytail OpenClaw skill generator — Zig 0.16.
//!
//! Emits the OpenClaw / ClawHub skill package (`.openclaw/skills/<name>/SKILL.md`)
//! from the canonical `skills/<name>/SKILL.md`. A 1:1 port of the retired
//! `scripts/build-openclaw-skills.js`: OpenClaw skills are SKILL.md (frontmatter +
//! body), the same format ponytail uses, with one rule — `description` must be a
//! single line under 160 chars. The canonical descriptions are long (tuned for
//! Claude's skill picker), so each ships a short one here. The body is copied
//! VERBATIM from the source so the ruleset never drifts; only the frontmatter is
//! rewritten.
//!
//! Run (from the repo root, the parent of `skills/` and `.openclaw/`):
//!
//!   ponytail-openclaw
//!
//! Repo root resolution: $PONYTAIL_REPO_ROOT if set, else "." (the cwd). The
//! generator reads `<root>/skills/<name>/SKILL.md` and writes
//! `<root>/.openclaw/skills/<name>/SKILL.md` through `common.safeWriteFlag` — the
//! same symlink-safe, atomic, O_NOFOLLOW writer the runtime hooks use. Output
//! dirs must sit under a trusted base ($HOME / $TMPDIR / $CLAUDE_CONFIG_DIR), so
//! the normal cases (repo under $HOME, or a tmp test workspace) write cleanly and
//! a hostile path is refused rather than clobbered.
//!
//! tests/openclaw-skills.test.js execs this binary into a tmp workspace and
//! asserts the emitted files are byte-identical to the committed copies (drift
//! guard) — the JS generator and its in-process render() are gone.

const std = @import("std");
const common = @import("common.zig");

/// Homepage stamped into every OpenClaw frontmatter (matches the JS HOMEPAGE).
const HOMEPAGE = "https://github.com/DietrichGebert/ponytail";

/// The skill set + their short OpenClaw descriptions. Byte-for-byte the JS
/// DESCRIPTIONS table (scripts/build-openclaw-skills.js). Order is the emission
/// order; the test iterates the same set.
const Skill = struct { name: []const u8, description: []const u8 };
const SKILLS = [_]Skill{
    .{ .name = "ponytail", .description = "Lazy senior dev mode. Forces the simplest, shortest solution that works: YAGNI, stdlib first, no unrequested abstractions." },
    .{ .name = "ponytail-review", .description = "Review a diff for over-engineering. Finds what to delete: reinvented stdlib, needless deps, speculative abstractions. One line per finding." },
    .{ .name = "ponytail-audit", .description = "Audit the whole repo for over-engineering. A ranked list of what to delete, simplify, or replace with stdlib or native features." },
    .{ .name = "ponytail-debt", .description = "Harvest every ponytail: shortcut comment into one debt ledger, so deferrals get tracked instead of forgotten. One-shot report." },
    .{ .name = "ponytail-gain", .description = "Show ponytail measured impact as a scoreboard: less code, less cost, more speed, from the benchmark medians. One-shot display." },
    .{ .name = "ponytail-help", .description = "Quick reference for ponytail's modes, skills, and commands. One-shot display." },
};

const GenError = error{
    DescriptionInvalid,
    SourceMissing,
    NoFrontmatter,
} || std.mem.Allocator.Error;

/// ponytail: Fence-based frontmatter strip, an intentional simplification — NOT a
/// full YAML parser. Strips a leading `^---\n ... \n---\n?` block, returning the
/// body slice; mirrors the JS regex /^---\n[\s\S]*?\n---\n?/ (the FIRST `\n---`
/// terminator after the opening `---\n`). Ceiling: a `---` inside the frontmatter
/// body (e.g. a multi-line YAML value) would terminate early — fine for our skill
/// frontmatter which never contains one. Upgrade path: a real YAML scanner if a
/// skill ever needs `---` in its frontmatter. Errors if the block is absent.
fn stripFrontmatter(src: []const u8) GenError![]const u8 {
    if (!std.mem.startsWith(u8, src, "---\n")) return error.NoFrontmatter;
    // Find the closing fence: the first "\n---" after the opening line.
    const after_open = src["---\n".len..];
    const close_rel = std.mem.indexOf(u8, after_open, "\n---") orelse return error.NoFrontmatter;
    // Position just past "\n---".
    var idx = "---\n".len + close_rel + "\n---".len;
    // Consume an optional trailing newline (the JS \n? after the closing ---).
    if (idx < src.len and src[idx] == '\n') idx += 1;
    return src[idx..];
}

/// Validate a description against OpenClaw's frontmatter rule: one line, no double
/// quotes (we wrap it in "), under or at 160 chars. Mirrors the JS render() guard.
fn descriptionOk(desc: []const u8) bool {
    if (desc.len > 160) return false;
    if (std.mem.indexOfScalar(u8, desc, '\n') != null) return false;
    if (std.mem.indexOfScalar(u8, desc, '"') != null) return false;
    return true;
}

/// Build the full OpenClaw SKILL.md for `skill` over the canonical source body.
/// Caller owns the returned slice. Byte-identical to the JS render(name).
/// File-private: callers and tests live in this file (the public surface is the
/// binary's stdout, not a Zig symbol).
fn render(gpa: std.mem.Allocator, skill: Skill, source: []const u8) GenError![]u8 {
    if (!descriptionOk(skill.description)) return error.DescriptionInvalid;
    const body = try stripFrontmatter(source);
    return std.fmt.allocPrint(
        gpa,
        "---\nname: {s}\ndescription: \"{s}\"\nhomepage: {s}\nlicense: MIT\n---\n{s}",
        .{ skill.name, skill.description, HOMEPAGE, body },
    );
}

/// Resolve the repo root: $PONYTAIL_REPO_ROOT or "." (cwd).
fn repoRoot() []const u8 {
    if (common.getenv("PONYTAIL_REPO_ROOT")) |r| {
        if (r.len > 0) return r;
    }
    return ".";
}

/// Normalize CRLF → LF in `src`, returning an owned copy (caller frees). Matches
/// the JS `.replace(/\r\n/g, '\n')` on the source before frontmatter handling.
fn normalizeNewlines(gpa: std.mem.Allocator, src: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        if (src[i] == '\r' and i + 1 < src.len and src[i + 1] == '\n') continue;
        try out.append(gpa, src[i]);
    }
    return out.toOwnedSlice(gpa);
}

/// Generate one skill: read `<root>/skills/<name>/SKILL.md`, render the OpenClaw
/// variant, write `<root>/.openclaw/skills/<name>/SKILL.md` via safeWriteFlag.
fn generateOne(gpa: std.mem.Allocator, root: []const u8, skill: Skill) !void {
    const src_path = try std.fs.path.join(gpa, &.{ root, "skills", skill.name, "SKILL.md" });
    defer gpa.free(src_path);

    const raw = common.readSmallFile(gpa, src_path) orelse return error.SourceMissing;
    defer gpa.free(raw);

    const normalized = try normalizeNewlines(gpa, raw);
    defer gpa.free(normalized);

    const out = try render(gpa, skill, normalized);
    defer gpa.free(out);

    const out_path = try std.fs.path.join(gpa, &.{ root, ".openclaw", "skills", skill.name, "SKILL.md" });
    defer gpa.free(out_path);

    // Pre-create the `<root>/.openclaw/skills/<name>/` chain (safeWriteFlag only
    // mkdir's the leaf parent, and these intermediate dirs don't exist yet).
    if (std.fs.path.dirname(out_path)) |out_dir| try common.makePathRecursive(gpa, out_dir);

    try common.safeWriteFlag(gpa, out_path, out);
    // Tell the caller (and CI logs) which file landed; relative-ish to root.
    common.writeStdout("wrote ");
    common.writeStdout(out_path);
    common.writeStdout("\n");
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // Resolve to an absolute root so a relative default ("." when
    // $PONYTAIL_REPO_ROOT is unset) isn't refused by safeWriteFlag's
    // ancestorUnsafe, which prefix-matches against the absolute trusted bases.
    // absRoot always returns an owned slice (realpath'd or a dupe), so always free.
    const root = try common.absRoot(gpa, repoRoot());
    defer gpa.free(root);
    var failed = false;
    for (SKILLS) |skill| {
        generateOne(gpa, root, skill) catch |err| {
            // Report and keep going so one bad skill does not mask the rest, then
            // exit non-zero so CI / the test notices.
            common.writeStdout("error: ");
            common.writeStdout(skill.name);
            common.writeStdout(": ");
            common.writeStdout(@errorName(err));
            common.writeStdout("\n");
            failed = true;
        };
    }
    if (failed) std.process.exit(1);
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "stripFrontmatter drops the leading --- block, keeps the body verbatim" {
    const src = "---\nname: x\ndescription: y\n---\n# Heading\n\nbody line\n";
    const body = try stripFrontmatter(src);
    try std.testing.expectEqualStrings("# Heading\n\nbody line\n", body);
}

test "stripFrontmatter requires an opening fence" {
    try std.testing.expectError(error.NoFrontmatter, stripFrontmatter("no frontmatter here\n"));
}

test "stripFrontmatter stops at the FIRST closing fence (non-greedy)" {
    // A body that itself contains a '---' later must not be over-consumed.
    const src = "---\nname: x\n---\nbody\n\n---\nmore body\n";
    const body = try stripFrontmatter(src);
    try std.testing.expectEqualStrings("body\n\n---\nmore body\n", body);
}

test "render produces the OpenClaw frontmatter + verbatim body" {
    const gpa = std.testing.allocator;
    const skill: Skill = .{ .name = "ponytail", .description = "Short desc." };
    const source = "---\nname: ponytail\ndescription: >\n  long\n---\n# Ponytail\n\nrules\n";
    const out = try render(gpa, skill, source);
    defer gpa.free(out);
    try std.testing.expectEqualStrings(
        "---\nname: ponytail\ndescription: \"Short desc.\"\nhomepage: " ++ HOMEPAGE ++ "\nlicense: MIT\n---\n# Ponytail\n\nrules\n",
        out,
    );
}

test "render rejects an over-long / quoted / multiline description" {
    const gpa = std.testing.allocator;
    const source = "---\nx\n---\nbody\n";
    const long = "x" ** 161;
    try std.testing.expectError(error.DescriptionInvalid, render(gpa, .{ .name = "n", .description = long }, source));
    try std.testing.expectError(error.DescriptionInvalid, render(gpa, .{ .name = "n", .description = "has \" quote" }, source));
    try std.testing.expectError(error.DescriptionInvalid, render(gpa, .{ .name = "n", .description = "two\nlines" }, source));
}

test "every shipped description satisfies the OpenClaw one-line <160 rule" {
    for (SKILLS) |skill| {
        try std.testing.expect(descriptionOk(skill.description));
    }
}

test "normalizeNewlines collapses CRLF to LF" {
    const gpa = std.testing.allocator;
    const out = try normalizeNewlines(gpa, "a\r\nb\rc\nd");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("a\nb\rc\nd", out);
}
