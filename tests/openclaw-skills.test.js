#!/usr/bin/env node
// The OpenClaw skill package (.openclaw/skills/) is generated from skills/ by the
// Zig `ponytail-openclaw` binary (zig/src/openclaw.zig — the JS generator
// scripts/build-openclaw-skills.js was retired in the pure-Zig cutover).
//
// This test execs that binary into a throwaway workspace and asserts:
//   1. each emitted .openclaw/skills/<name>/SKILL.md is byte-identical to the
//      committed copy (drift guard — committed copies must stay in sync), and
//   2. each emitted SKILL.md parses with a single-line `description` under 160
//      chars (OpenClaw's frontmatter rule).
//
// If the binary is not built it fails loudly with a build hint rather than
// silently skipping.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const REPO_ROOT = path.resolve(__dirname, "..");

const NAMES = [
	"ponytail",
	"ponytail-review",
	"ponytail-audit",
	"ponytail-debt",
	"ponytail-gain",
	"ponytail-help",
];

function resolveBin() {
	const candidates = [
		process.env.PONYTAIL_OPENCLAW_BIN,
		path.join(REPO_ROOT, "zig", "zig-out", "bin", "ponytail-openclaw"),
		path.join(REPO_ROOT, "bin", "ponytail-openclaw"),
	].filter(Boolean);
	for (const c of candidates) {
		try {
			if (fs.existsSync(c)) return c;
		} catch (_e) {
			// keep probing
		}
	}
	return null;
}

const bin = resolveBin();

// Generate once into a throwaway workspace under $TMPDIR (a trusted base for the
// Zig symlink-safe writer), with the canonical skills/ copied in.
let workspace = null;
function generate() {
	if (workspace) return workspace;
	const ws = fs.mkdtempSync(path.join(os.tmpdir(), "ponytail-openclaw-"));
	fs.cpSync(path.join(REPO_ROOT, "skills"), path.join(ws, "skills"), {
		recursive: true,
	});
	execFileSync(bin, [], {
		env: { ...process.env, PONYTAIL_REPO_ROOT: ws },
		encoding: "utf8",
	});
	workspace = ws;
	return ws;
}

test.after(() => {
	if (workspace) {
		try {
			fs.rmSync(workspace, { recursive: true, force: true });
		} catch (_e) {
			// best-effort cleanup
		}
	}
});

test("ponytail-openclaw binary is built (generator prerequisite)", () => {
	assert.ok(
		bin,
		"ponytail-openclaw binary not found — build it: (cd zig && zig build -Dtool=ponytail), " +
			"or set PONYTAIL_OPENCLAW_BIN.",
	);
});

for (const name of NAMES) {
	test(`${name}: emitted OpenClaw skill is byte-identical to the committed copy`, (t) => {
		if (!bin) return t.skip("binary not built (covered by prerequisite test)");
		const ws = generate();
		const emitted = fs.readFileSync(
			path.join(ws, ".openclaw", "skills", name, "SKILL.md"),
			"utf8",
		);
		const committed = fs.readFileSync(
			path.join(REPO_ROOT, ".openclaw", "skills", name, "SKILL.md"),
			"utf8",
		);
		assert.equal(
			emitted,
			committed,
			`stale — regenerate: (cd zig && zig build -Dtool=ponytail) && ` +
				`PONYTAIL_REPO_ROOT="${REPO_ROOT}" zig/zig-out/bin/ponytail-openclaw`,
		);
	});

	test(`${name}: emitted frontmatter has a single-line description under 160 chars`, (t) => {
		if (!bin) return t.skip("binary not built (covered by prerequisite test)");
		const ws = generate();
		const md = fs.readFileSync(
			path.join(ws, ".openclaw", "skills", name, "SKILL.md"),
			"utf8",
		);
		const fm = md.match(/^---\n([\s\S]*?)\n---\n/);
		assert.ok(fm, `${name}: no frontmatter block`);
		const m = fm[1].match(/^description: "([^"\n]*)"$/m);
		assert.ok(m, `${name}: description is not a single-line quoted scalar`);
		assert.ok(m[1].length <= 160, `${name}: description exceeds 160 chars`);
		// name key present and matches the skill.
		assert.ok(
			new RegExp(`^name: ${name}$`, "m").test(fm[1]),
			`${name}: name key mismatch`,
		);
	});
}
