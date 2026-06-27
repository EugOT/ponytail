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
