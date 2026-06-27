#!/usr/bin/env node
// Hook-shim unit checks for the JS modules that survive the pure-Zig cutover.
//
// The SessionStart / UserPromptSubmit RUNTIME (flag write, mode tracking, host
// output envelopes) now lives in the Zig binaries (zig/src/activate.zig,
// main.zig, common.zig) and is exercised by `zig build test`. The old Node
// spawn tests against hooks/ponytail-activate.js + hooks/ponytail-mode-tracker.js
// were removed with those files. What stays here is the pure-helper contract the
// surviving JS shims (pi / opencode / instructions bridge) still consume from
// hooks/ponytail-config.js.

const assert = require("node:assert");
const test = require("node:test");
const fs = require("node:fs");
const path = require("node:path");

const root = path.join(__dirname, "..");

// isShellSafe gates the statusline setup snippet (issue #200): ordinary install
// paths pass, paths carrying shell metacharacters are rejected so they never get
// embedded in a shell command.
const { isShellSafe } = require("../hooks/ponytail-config");
assert.equal(
	isShellSafe(
		"C:\\Users\\x\\.claude\\plugins\\ponytail\\hooks\\ponytail-statusline.ps1",
	),
	true,
);
assert.equal(
	isShellSafe("/home/u/.claude/plugins/ponytail/hooks/ponytail-statusline.sh"),
	true,
);
assert.equal(isShellSafe('/tmp/a"&calc.exe&"/x.sh'), false);
assert.equal(isShellSafe("/tmp/$(calc)/x.sh"), false);
assert.equal(isShellSafe("/tmp/a;rm -rf/x.sh"), false);

console.log("hook helper checks passed");

// Smoke test for the new pure-shell layer (R6 cutover): the lifecycle-hook
// manifest launches binaries by NAME through bin/ponytail-launch, and install.sh
// is what actually deploys those named binaries into the hooks dir. Guard that
// the manifest's launched names stay in lockstep with install.sh's deploy list,
// and that the launcher exists — otherwise a hook could reference a binary the
// installer never lays down (or vice versa).
test("install.sh deploys every binary the hook manifest launches", () => {
	const launchBash = fs.readFileSync(
		path.join(root, "bin", "ponytail-launch"),
		"utf8",
	);
	assert.match(
		launchBash,
		/exec "\$b"/,
		"ponytail-launch must exec the resolved binary",
	);

	const manifest = JSON.parse(
		fs.readFileSync(
			path.join(root, "hooks", "claude-codex-hooks.json"),
			"utf8",
		),
	);
	// Every command launches `ponytail-launch <binary-name>`; collect those names.
	const launched = new Set();
	for (const entry of Object.values(manifest.hooks).flat()) {
		for (const hook of entry.hooks) {
			for (const cmd of [hook.command, hook.commandWindows].filter(Boolean)) {
				const m = cmd.match(/ponytail-launch(?:\.ps1)?"?\s+(ponytail-[\w-]+)/);
				assert.ok(m, `cannot parse launched binary from command: ${cmd}`);
				launched.add(m[1]);
			}
		}
	}
	assert.ok(launched.size > 0, "expected at least one launched binary name");

	// install.sh declares HOOK_BINS=(...) — the set it deploys into the hooks dir.
	const installSh = fs.readFileSync(path.join(root, "install.sh"), "utf8");
	const hookBinsMatch = installSh.match(/HOOK_BINS=\(([^)]*)\)/);
	assert.ok(hookBinsMatch, "install.sh must declare HOOK_BINS=(...)");
	const deployed = new Set(hookBinsMatch[1].split(/\s+/).filter(Boolean));

	// Every binary the manifest launches must be one install.sh actually deploys.
	for (const name of launched) {
		assert.ok(
			deployed.has(name),
			`hook manifest launches '${name}' but install.sh HOOK_BINS does not deploy it`,
		);
	}

	// install.sh's wire_settings_fresh must reference each deployed hook so the
	// settings.json it writes actually points at the binaries it lays down.
	for (const name of deployed) {
		assert.ok(
			installSh.includes(name),
			`install.sh deploys '${name}' but never references it in settings wiring`,
		);
	}
});
