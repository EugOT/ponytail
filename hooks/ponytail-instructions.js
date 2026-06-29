#!/usr/bin/env node
// Ponytail instruction builder — FALLBACK-ONLY (Option A, zig-rewrite plan §2).
//
// The ruleset hot path is pure Zig: the pi/opencode shims exec the
// `ponytail-instructions` binary (zig/src/instructions.zig, sharing
// common.getInstructions) through hooks/ponytail-instructions-bin.js. This module
// no longer runs on the hot path — it persists for exactly two reasons:
//
//   1. `getPonytailInstructions` is the bridge's JS FALLBACK when the Zig binary
//      is absent/unexecutable (correctness over purity — the integration contract
//      never breaks). The differential test (tests/instructions-differential.test.js)
//      pins this fallback byte-identical to the binary for every mode.
//   2. `filterSkillBodyForMode` is a pure helper pi's tests import directly
//      (pi-extension/test/helpers.test.js); it is NOT part of the injection path.
//
// Do not re-route the shims back through this builder — the Zig binary is the
// single source of the ruleset. Edit skills/ponytail/SKILL.md for behavior.

const fs = require("node:fs");
const path = require("node:path");
const {
	DEFAULT_MODE,
	normalizeMode,
	normalizePersistedMode,
} = require("./ponytail-config");

const INDEPENDENT_MODES = new Set(["review"]);
const SKILL_PATH = path.join(__dirname, "..", "skills", "ponytail", "SKILL.md");

function filterSkillBodyForMode(body, mode) {
	const effectiveMode = normalizeMode(mode) || DEFAULT_MODE;
	const withoutFrontmatter = String(body || "").replace(
		/^---[\s\S]*?---\s*/,
		"",
	);

	// Only the intensity table rows and worked examples are mode-specific, and
	// both are keyed by a mode name (lite/full/ultra). A bullet whose label is
	// not a mode — e.g. "No unrequested abstractions: ..." — is a normal rule
	// and must be kept verbatim.
	return withoutFrontmatter
		.split(/\r?\n/)
		.filter((line) => {
			const tableLabel = line.match(/^\|\s*\*\*(.+?)\*\*\s*\|/);
			if (tableLabel) {
				const labelMode = normalizeMode(tableLabel[1].trim());
				if (labelMode) return labelMode === effectiveMode;
			}

			const exampleLabel = line.match(/^-\s*([^:]+):\s*/);
			if (exampleLabel) {
				const labelMode = normalizeMode(exampleLabel[1].trim());
				if (labelMode) return labelMode === effectiveMode;
			}

			return true;
		})
		.join("\n");
}

function getFallbackInstructions(mode) {
	return (
		"PONYTAIL MODE ACTIVE — level: " +
		mode +
		"\n\n" +
		"You are a lazy senior developer. Lazy means efficient, not careless. The best code is the code never written.\n\n" +
		"## Persistence\n\n" +
		'ACTIVE EVERY RESPONSE. No drift back to over-building. Still active if unsure. Off only: "stop ponytail" / "normal mode".\n\n' +
		"Current level: **" +
		mode +
		"**. Switch: `/ponytail lite|full|ultra`.\n\n" +
		"## The ladder\n\n" +
		"Before any code, stop at the first rung that holds:\n" +
		"1. Does this need to be built at all? (YAGNI)\n" +
		"2. Does the standard library do this? Use it.\n" +
		"3. Does a native platform feature cover it? Use it.\n" +
		"4. Does an already-installed dependency solve it? Use it.\n" +
		"5. Can this be one line? Make it one line.\n" +
		"6. Only then: write the minimum code that works.\n\n" +
		"## Rules\n\n" +
		"No abstractions that were not requested. No avoidable dependencies. No boilerplate nobody asked for. " +
		"Deletion over addition. Boring over clever. Fewest files possible. " +
		"Ship the lazy version and question the complex request in the same response — never stall. " +
		"Between two same-size stdlib options, pick the one correct on edge cases. " +
		"Mark intentional simplifications with a `ponytail:` comment — a shortcut with a known ceiling names the ceiling and the upgrade path in the comment.\n\n" +
		"## Output\n\n" +
		"Code first. Then at most three short lines: what was skipped, when to add it. " +
		"If the explanation is longer than the code, delete the explanation. " +
		"Explanation the user explicitly asked for is not debt, give it in full.\n\n" +
		"## When NOT to be lazy\n\n" +
		"Never simplify away: input validation at trust boundaries, error handling that prevents data loss, " +
		"security measures, accessibility basics, the calibration real hardware needs (the platform is never the spec ideal), anything the user explicitly asked to keep. " +
		"Lazy code without its check is unfinished: non-trivial logic leaves ONE runnable check behind (assert-based demo/self-check or one small test file; no frameworks). Trivial one-liners need no test.\n\n" +
		"## Boundaries\n\n" +
		'Ponytail governs what you build, not how you talk. "stop ponytail" or "normal mode": revert. Level persists until changed or session end.'
	);
}

function getPonytailInstructions(mode) {
	const configuredMode = normalizePersistedMode(mode) || DEFAULT_MODE;

	if (INDEPENDENT_MODES.has(configuredMode)) {
		return `PONYTAIL MODE ACTIVE — level: ${configuredMode}. Behavior defined by /ponytail-${configuredMode} skill.`;
	}

	// configuredMode is already a normalized runtime/config mode here; for the
	// non-independent modes it is also a valid runtime mode, so it IS the
	// effective intensity. (normalizeMode on it is a no-op; kept implicit.)
	const effectiveMode = configuredMode;

	try {
		return (
			"PONYTAIL MODE ACTIVE — level: " +
			effectiveMode +
			"\n\n" +
			filterSkillBodyForMode(fs.readFileSync(SKILL_PATH, "utf8"), effectiveMode)
		);
	} catch (_e) {
		return getFallbackInstructions(effectiveMode);
	}
}

module.exports = {
	filterSkillBodyForMode,
	getFallbackInstructions,
	getPonytailInstructions,
};
