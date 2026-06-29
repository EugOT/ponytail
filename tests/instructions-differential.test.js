#!/usr/bin/env node
// LOCKED DIFFERENTIAL GATE — Zig `ponytail-instructions` binary == JS builder.
//
// This is the guardrail that makes every JS shrink in the Zig-rewrite plan
// (docs/zig-rewrite-plan-2026-06-27.md §"Sequenced plan" step 1) safe: before we
// trim hooks/ponytail-instructions.js to a fallback-only stub, we PROVE the Zig
// binary the pi/opencode shims already route through produces byte-identical
// output to the JS builder for every mode.
//
// Contract per mode (matches hooks/ponytail-instructions-bin.js buildInstructions
// and zig/src/instructions.zig main):
//   - lite / full / ultra / review : binary stdout === getPonytailInstructions(mode), byte-for-byte.
//   - off                          : the binary prints NOTHING (the shims special-case "off"
//                                     BEFORE calling, injecting nothing); the JS builder still
//                                     returns a full body, but that divergence is never observable
//                                     because the shims short-circuit. We assert the binary is empty
//                                     for off and that the JS builder is non-empty (the documented
//                                     asymmetry), so a regression that makes the binary emit a body
//                                     for "off" is caught.
//
// If the binary is not built, the test fails loudly with a build hint rather than
// silently skipping — a green-by-absence differential would defeat the guardrail.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const {
	getPonytailInstructions,
} = require("../hooks/ponytail-instructions.js");

const REPO_ROOT = path.resolve(__dirname, "..");

function resolveBin() {
	const candidates = [
		process.env.PONYTAIL_INSTRUCTIONS_BIN,
		path.join(REPO_ROOT, "zig", "zig-out", "bin", "ponytail-instructions"),
		path.join(REPO_ROOT, "bin", "ponytail-instructions"),
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

function runBinary(bin, mode) {
	return execFileSync(bin, [], {
		env: { ...process.env, PONYTAIL_INSTRUCTIONS_MODE: String(mode) },
		encoding: "utf8",
		maxBuffer: 1024 * 1024,
	});
}

const bin = resolveBin();

// Fail loudly if the binary is missing — never let the differential pass by
// being silently un-runnable.
test("ponytail-instructions binary is built (differential prerequisite)", () => {
	assert.ok(
		bin,
		"ponytail-instructions binary not found — build it first: " +
			"(cd zig && zig build -Dtool=ponytail), or set PONYTAIL_INSTRUCTIONS_BIN.",
	);
});

// The injecting modes: binary stdout must equal the JS builder byte-for-byte.
for (const mode of ["lite", "full", "ultra", "review"]) {
	test(`mode=${mode}: Zig binary output === JS getPonytailInstructions`, (t) => {
		if (!bin) return t.skip("binary not built (covered by prerequisite test)");
		const js = getPonytailInstructions(mode);
		const zig = runBinary(bin, mode);
		assert.equal(zig, js, `differential drift for mode=${mode}`);
	});
}

// "off": binary prints nothing; JS builder returns a non-empty body (the shims
// short-circuit off before calling, so the asymmetry is never observable).
test("mode=off: Zig binary prints nothing; JS builder returns a body", (t) => {
	if (!bin) return t.skip("binary not built (covered by prerequisite test)");
	const js = getPonytailInstructions("off");
	const zig = runBinary(bin, "off");
	assert.equal(zig.length, 0, "binary must emit nothing for off");
	assert.ok(
		js.length > 0,
		"JS builder returns a full body for off (documented asymmetry)",
	);
});
