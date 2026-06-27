#!/usr/bin/env node
// Regression guard for the lifecycle-hook manifests after the pure-Zig cutover.
//
// Original issue #19: on Windows the lifecycle hooks ran via PowerShell, which
// does NOT expand cmd.exe-style %VAR% — it needs $env:VAR — and the command had
// to point at a target that actually ships. The pure-Zig cutover replaced the
// `node hooks/ponytail-*.js` commands with the bin/ponytail-launch resolver
// (which finds/downloads the native Zig hook binary), so this test now guards:
//   1. no command uses cmd.exe %VAR% syntax (would break under PowerShell);
//   2. every command points at the shipped bin/ponytail-launch resolver;
//   3. Claude + Codex manifests reference the shared host-specific hook config.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.join(__dirname, "..");
const HOOKS_JSON = "hooks/claude-codex-hooks.json";
const HOST_PLUGIN_MANIFESTS = [
	".claude-plugin/plugin.json",
	".codex-plugin/plugin.json",
];
// cmd.exe variable syntax (%FOO%); PowerShell leaves it literal, breaking the path.
const CMD_VAR_SYNTAX = /%[A-Za-z_][A-Za-z0-9_]*%/;
// The pure-Zig hook resolver every lifecycle command launches.
const LAUNCH_TARGET = /bin[\\/]ponytail-launch/;

// Read inside each case so a missing/malformed file fails as a clean assertion,
// not a load-time crash.
function commandHooks() {
	const config = JSON.parse(
		fs.readFileSync(path.join(root, HOOKS_JSON), "utf8"),
	);
	return Object.values(config.hooks)
		.flat()
		.flatMap((entry) => entry.hooks);
}

function allCommands(hook) {
	return [hook.command, hook.commandWindows].filter(Boolean);
}

test("no hook command uses cmd.exe %VAR% syntax (breaks under PowerShell)", () => {
	const commands = commandHooks().flatMap(allCommands);
	assert.ok(commands.length > 0, "expected at least one hook command");
	for (const cmd of commands) {
		assert.doesNotMatch(
			cmd,
			CMD_VAR_SYNTAX,
			`command uses cmd.exe %VAR%: ${cmd}`,
		);
	}
});

test("every hook command launches the bin/ponytail-launch resolver, which ships", () => {
	for (const hook of commandHooks()) {
		for (const cmd of allCommands(hook)) {
			assert.match(
				cmd,
				LAUNCH_TARGET,
				`hook command does not launch ponytail-launch: ${cmd}`,
			);
		}
	}
	// The resolver itself must exist on disk so the plugin can run it.
	assert.ok(
		fs.existsSync(path.join(root, "bin", "ponytail-launch")),
		"bin/ponytail-launch is referenced by the hook manifest but missing on disk",
	);
});

test("Claude and Codex manifests point at the shared host-specific hook config", () => {
	for (const rel of HOST_PLUGIN_MANIFESTS) {
		const manifest = JSON.parse(fs.readFileSync(path.join(root, rel), "utf8"));
		assert.equal(
			manifest.hooks,
			`./${HOOKS_JSON}`,
			`${rel} must not rely on root hooks auto-discovery`,
		);
	}
});
