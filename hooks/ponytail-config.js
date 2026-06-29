#!/usr/bin/env node
// ponytail — shared configuration resolver
//
// Resolution order for default mode:
//   1. PONYTAIL_DEFAULT_MODE environment variable
//   2. Config file defaultMode field:
//      - $XDG_CONFIG_HOME/ponytail/config.json (any platform, if set)
//      - ~/.config/ponytail/config.json (macOS / Linux fallback)
//      - %APPDATA%\ponytail\config.json (Windows fallback)
//   3. 'full'

const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const { execFileSync } = require("node:child_process");
const { safeWriteFlag } = require("./ponytail-fs-safe");

// ── Option B exec bridge (zig-rewrite plan §1.5) ─────────────────────────────
// getDefaultMode / writeDefaultMode prefer the Zig `ponytail-config` verb
// (get-default / set-default), which resolve and persist the default mode with
// the IDENTICAL env→config.json→"full" logic and the same symlink-safe write.
// Both fall back to the in-process JS implementation (jsGetDefaultMode /
// jsWriteDefaultMode) when the binary is absent — the pi/opencode contract never
// breaks. The pure string helpers (normalize*/isDeactivationCommand) stay JS:
// they are called per-keystroke/per-turn in-process and have no I/O to move out.

function resolveConfigBin() {
	const repoRoot = path.resolve(__dirname, "..");
	const candidates = [
		process.env.PONYTAIL_CONFIG_BIN,
		path.join(repoRoot, "zig", "zig-out", "bin", "ponytail-config"),
		path.join(repoRoot, "bin", "ponytail-config"),
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

const DEFAULT_MODE = "full";
const VALID_MODES = ["off", "lite", "full", "ultra", "review"];
const RUNTIME_MODES = ["off", "lite", "full", "ultra"];

// Hard wall-clock bound for the exec-first Zig bridge. The verb does one small
// config.json read/write and returns immediately; 2s is generous headroom while
// still guaranteeing a hung binary can't block a hook path — on timeout
// execFileSync throws and the in-process JS implementation takes over.
const EXEC_TIMEOUT_MS = 2000;

function normalizeMode(mode) {
	if (typeof mode !== "string") return null;
	const normalized = mode.trim().toLowerCase();
	return RUNTIME_MODES.includes(normalized) ? normalized : null;
}

function normalizeConfigMode(mode) {
	if (typeof mode !== "string") return null;
	const normalized = mode.trim().toLowerCase();
	return VALID_MODES.includes(normalized) ? normalized : null;
}

function normalizePersistedMode(mode) {
	return normalizeMode(mode) || normalizeConfigMode(mode);
}

// "stop ponytail" / "normal mode" turn ponytail off, but only as a standalone
// command. Matching the phrase anywhere in the message turned it off mid-task
// for ordinary requests like "add a normal mode toggle" — so require the whole
// message to be the command, ignoring case and trailing punctuation.
function isDeactivationCommand(text) {
	const t = String(text || "")
		.trim()
		.toLowerCase()
		.replace(/[.!?\s]+$/, "");
	return t === "stop ponytail" || t === "normal mode";
}

// ponytail: only embed the plugin install path in a statusline shell command when
// it's made of ordinary path characters. An allowlist beats escaping every shell's
// metacharacters; a hostile clone path (quotes, &, $, backtick, ;, etc.) falls back
// to manual setup instead. Allows : \ / for normal Windows and POSIX paths. Full
// per-shell escaper only if a real need appears.
function isShellSafe(p) {
	return typeof p === "string" && /^[A-Za-z0-9 _.\-:/\\~]+$/.test(p);
}

function getConfigDir() {
	if (process.env.XDG_CONFIG_HOME) {
		return path.join(process.env.XDG_CONFIG_HOME, "ponytail");
	}
	if (process.platform === "win32") {
		return path.join(
			process.env.APPDATA || path.join(os.homedir(), "AppData", "Roaming"),
			"ponytail",
		);
	}
	return path.join(os.homedir(), ".config", "ponytail");
}

function getConfigPath() {
	return path.join(getConfigDir(), "config.json");
}

function getClaudeDir() {
	// ponytail: CLAUDE_CONFIG_DIR overrides ~/.claude, matching Claude Code.
	return process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), ".claude");
}

function jsGetDefaultMode() {
	// 1. Environment variable (highest priority)
	const envMode = process.env.PONYTAIL_DEFAULT_MODE;
	if (envMode && VALID_MODES.includes(envMode.toLowerCase())) {
		return envMode.toLowerCase();
	}

	// 2. Config file
	try {
		const configPath = getConfigPath();
		const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
		if (
			config.defaultMode &&
			VALID_MODES.includes(config.defaultMode.toLowerCase())
		) {
			return config.defaultMode.toLowerCase();
		}
	} catch (_e) {
		// Config file doesn't exist or is invalid — fall through
	}

	// 3. Default
	return DEFAULT_MODE;
}

function jsWriteDefaultMode(mode) {
	const normalized = normalizeConfigMode(mode);
	if (!normalized) return null;

	const configPath = getConfigPath();
	// Symlink-safe atomic write — config.json sits at a predictable path the user
	// owns, so route it through the same clobber-resistant writer as the flag.
	// safeWriteFlag returns false on a refused (symlinked) target or any fs error;
	// surface that as null so a caller never reports a persisted mode that was not
	// actually written.
	if (
		!safeWriteFlag(
			configPath,
			JSON.stringify({ defaultMode: normalized }, null, 2),
		)
	) {
		return null;
	}
	return normalized;
}

// Exec-first default-mode resolve: prefer the Zig `ponytail-config get-default`
// verb (same env→config→full logic), fall back to the in-process JS resolver.
function getDefaultMode() {
	const bin = resolveConfigBin();
	if (bin) {
		try {
			const out = execFileSync(bin, [], {
				env: { ...process.env, PONYTAIL_CONFIG_CMD: "get-default" },
				encoding: "utf8",
				// Bound the synchronous call: these run on hook paths, so a hung
				// binary must not block the host session — on timeout execFileSync
				// throws and we fall through to the in-process JS resolver.
				timeout: EXEC_TIMEOUT_MS,
			}).trim();
			// The verb prints a whitelisted mode; trust only a recognized value.
			if (out && VALID_MODES.includes(out)) return out;
		} catch (_e) {
			// Binary missing/crashed → fall through to the JS resolver.
		}
	}
	return jsGetDefaultMode();
}

// Exec-first default-mode persist: prefer `ponytail-config set-default <mode>`
// (validates + symlink-safe-writes config.json), fall back to the JS writer.
// Returns the normalized mode written, or null if the mode was invalid.
function writeDefaultMode(mode) {
	const normalized = normalizeConfigMode(mode);
	if (!normalized) return null;

	const bin = resolveConfigBin();
	if (bin) {
		try {
			const out = execFileSync(bin, [], {
				env: {
					...process.env,
					PONYTAIL_CONFIG_CMD: "set-default",
					PONYTAIL_CONFIG_MODE: normalized,
				},
				encoding: "utf8",
				// Same hook-path timeout guard as getDefaultMode — a hung verb must
				// fall through to the JS writer rather than block the session.
				timeout: EXEC_TIMEOUT_MS,
			}).trim();
			if (out === normalized) return normalized;
			// Unexpected output → fall through so the JS writer still persists it.
		} catch (_e) {
			// Binary missing/refused → fall through to the JS writer.
		}
	}
	return jsWriteDefaultMode(mode);
}

module.exports = {
	DEFAULT_MODE,
	VALID_MODES,
	RUNTIME_MODES,
	getDefaultMode,
	jsGetDefaultMode,
	jsWriteDefaultMode,
	getConfigDir,
	getConfigPath,
	getClaudeDir,
	isShellSafe,
	normalizeMode,
	normalizeConfigMode,
	normalizePersistedMode,
	isDeactivationCommand,
	writeDefaultMode,
};
