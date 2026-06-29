#!/usr/bin/env node
// pz adapter (zig-rewrite plan §3.1) — the Zig `ponytail-pz` binary emits a
// first-class ponytail skill pz discovers by scanning the filesystem:
//   - project: <root>/.pz/skills/ponytail/SKILL.md
//   - global:  $HOME/.pz/skills/ponytail/SKILL.md
//
// pz loads skills by SCANNING skill files (no host plugin module), so the whole
// adapter is pure-Zig file emission — there is NO JS/ESM shim. This test execs
// the binary into a sandbox ($TMPDIR-rooted HOME + project root, both trusted
// bases for the symlink-safe writer) and asserts the emitted SKILL.md parses
// under pz's frontmatter rules (pz/src/core/skill.zig parseFrontmatter):
//
//   - opening `---\n` ... closing `---\n` fence,
//   - `key: value` lines split on the FIRST colon, value trimmed,
//   - pz's stripQuotes strips ONLY single quotes (never double) — so the
//     description is a single unquoted line (and must contain no double quote),
//   - name == ponytail, user_invocable == true, no `always:` key (pz has none;
//     it is model-invocable discovery, not force-injection).
//
// The emitted-vs-pz-loader parse was also checked directly against pz's own
// parseFrontmatter during development; this test pins the same contract in CI
// without depending on pz's build.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const REPO_ROOT = path.resolve(__dirname, "..");

function resolveBin() {
	const candidates = [
		process.env.PONYTAIL_PZ_BIN,
		path.join(REPO_ROOT, "zig", "zig-out", "bin", "ponytail-pz"),
		path.join(REPO_ROOT, "bin", "ponytail-pz"),
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

let sandbox = null;
function generate() {
	if (sandbox) return sandbox;
	// Sandbox under $TMPDIR so both the project root and the fake HOME sit under a
	// trusted base for the Zig symlink-safe writer.
	const sb = fs.mkdtempSync(path.join(os.tmpdir(), "ponytail-pz-"));
	fs.mkdirSync(path.join(sb, "home"));
	fs.mkdirSync(path.join(sb, "proj"));
	execFileSync(bin, [], {
		env: {
			...process.env,
			HOME: path.join(sb, "home"),
			PONYTAIL_REPO_ROOT: path.join(sb, "proj"),
		},
		encoding: "utf8",
	});
	sandbox = sb;
	return sb;
}

test.after(() => {
	if (sandbox) {
		try {
			fs.rmSync(sandbox, { recursive: true, force: true });
		} catch (_e) {
			// best-effort cleanup
		}
	}
});

// Parse a SKILL.md exactly the way pz does (parseFrontmatter / parseKV /
// stripQuotes from pz/src/core/skill.zig), returning { meta, body }.
function pzParse(content) {
	let open;
	if (content.startsWith("---\r\n")) open = 5;
	else if (content.startsWith("---\n")) open = 4;
	else return null;
	const afterOpen = content.slice(open);
	// closing fence: a line that is exactly '---' (with \n, \r\n, or EOF).
	const m = afterOpen.match(/(^|\n)---(\r?\n|$)/);
	if (!m) return null;
	const fenceStart = m.index + (m[1] ? m[1].length : 0);
	const fmBlock = afterOpen.slice(0, fenceStart);
	const body = afterOpen.slice(
		fenceStart + m[0].length - (m[1] ? m[1].length : 0),
	);

	const meta = {
		name: "",
		description: "",
		disable_model_invocation: false,
		user_invocable: false,
	};
	for (const rawLine of fmBlock.split("\n")) {
		const line = rawLine.replace(/\r$/, "");
		const colon = line.indexOf(":");
		if (colon < 0) continue;
		const key = line.slice(0, colon).trim();
		if (!key) continue;
		let val = line.slice(colon + 1).trim();
		// pz stripQuotes: strips ONLY a wrapping pair of single quotes.
		if (val.length >= 2 && val[0] === "'" && val[val.length - 1] === "'")
			val = val.slice(1, -1);
		if (key === "name") meta.name = val;
		else if (key === "description") meta.description = val;
		else if (key === "disable_model_invocation")
			meta.disable_model_invocation = val === "true";
		else if (key === "user_invocable") meta.user_invocable = val === "true";
	}
	return { meta, body };
}

test("ponytail-pz binary is built (adapter prerequisite)", () => {
	assert.ok(
		bin,
		"ponytail-pz binary not found — build it: (cd zig && zig build -Dtool=ponytail), or set PONYTAIL_PZ_BIN.",
	);
});

for (const scope of ["proj", "home"]) {
	test(`pz ${scope === "home" ? "global" : "project"} SKILL.md parses with pz frontmatter rules`, (t) => {
		if (!bin) return t.skip("binary not built (covered by prerequisite test)");
		const sb = generate();
		const p = path.join(sb, scope, ".pz", "skills", "ponytail", "SKILL.md");
		assert.ok(fs.existsSync(p), `${scope}: SKILL.md not emitted`);
		const content = fs.readFileSync(p, "utf8");

		const parsed = pzParse(content);
		assert.ok(parsed, `${scope}: pz could not parse the frontmatter`);
		assert.equal(parsed.meta.name, "ponytail", `${scope}: name`);
		assert.equal(parsed.meta.user_invocable, true, `${scope}: user_invocable`);
		assert.equal(
			parsed.meta.disable_model_invocation,
			false,
			`${scope}: disable_model_invocation`,
		);
		assert.ok(
			parsed.meta.description.length > 0,
			`${scope}: empty description`,
		);
		assert.ok(
			parsed.meta.description.length <= 160,
			`${scope}: description over 160`,
		);
		// pz does not strip double quotes — the writer must not wrap in them.
		assert.ok(
			!parsed.meta.description.includes('"'),
			`${scope}: description has a double quote`,
		);
		assert.ok(parsed.body.length > 0, `${scope}: empty body`);
		// No always:true (that is NullClaw, not pz) — discovery, not force-injection.
		assert.ok(!/^always:/m.test(content), `${scope}: unexpected always: key`);
	});
}

test("pz body is the mode-filtered ruleset, not the MODE ACTIVE wrapper", (t) => {
	if (!bin) return t.skip("binary not built (covered by prerequisite test)");
	const sb = generate();
	const content = fs.readFileSync(
		path.join(sb, "proj", ".pz", "skills", "ponytail", "SKILL.md"),
		"utf8",
	);
	const { body } = pzParse(content);
	// The pz body is the raw filtered SKILL body — NOT the "<TOOL> MODE ACTIVE"
	// header the instructions binary prepends.
	assert.ok(
		!body.includes("MODE ACTIVE"),
		"pz body should not carry the MODE ACTIVE wrapper",
	);
	assert.ok(body.includes("YAGNI"), "pz body should carry the ruleset");
});
