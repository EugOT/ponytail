# Upstream sync analysis — 2026-06-27

**id:** ponytail.upstream.analysis
**Scope:** classify every commit in `git log origin/main..upstream/main` (39 commits).
**Fork posture:** EugOT/ponytail is the **pure-Zig native-paths** fork. We retired the
Node hook chain (`hooks/ponytail-*.js`, `ponytail-config.js`, `ponytail-runtime.js`,
`ponytail-instructions.js`, `ponytail-mcp/*.js`) → Zig binaries under `zig/src/`.
**Intentionally still JS** (host requires an in-process module, not an external binary):
`pi-extension/index.js` and `.opencode/plugins/ponytail.mjs` + `.opencode/command/*.md`.

## Evidence (validated against live state, not docs)

- Remote: `git remote get-url upstream` → `https://github.com/DietrichGebert/ponytail.git`
- `git fetch upstream` exit 0, `git fetch origin` exit 0.
- `origin/main` = `feb5f80`, `upstream/main` = `c4d1925`.
- `git rev-list --count origin/main..upstream/main` = **39** (origin also **12 ahead** = the Zig rewrite).
- Fork retired the JS hooks: `ls hooks/` shows **no** `ponytail-subagent.js` / `ponytail-runtime.js`;
  no `ponytail-mcp/` dir; no `scripts/uninstall.js`; no `scripts/check-versions.js`.
- Fork Zig core present: `zig/src/{activate,main,statusline,common,instructions,mcp}.zig`.
- `common.zig` already has `writeHookOutput`/`buildHookOutputFor` with `.plain`/`.codex`/`.copilot`
  branches and a `SessionStart` path — but **no `SubagentStart` branch** (grep confirmed).
- Fork `skills/ponytail/SKILL.md` is **byte-identical to #253's parent** (`git diff origin/main:… dedc97c~1:…` empty, rc=0)
  and differs from `upstream/main:…` by **exactly the #253 delta** (25 ins / 9 del) → #253 content is genuinely missing and conflict-free.
- Fork keeps Python/JS benchmarks: `benchmarks/benchmark-local.py`, `benchmarks/loc.js`,
  `benchmarks/agentic/{run.py,tasks.py}` all present → benchmark fixes apply directly.
- Quality tooling present: `zigdoc` (rc 0), `ziglint` (rc 0). No Zig was edited here (doc-only), so no lint run was required.

## Classification key

- **ABSORB** — runtime feature/fix or benchmark/doc we want; applies to a file the fork still carries as-is (Python/JS benchmark, JS pi/opencode shim, SKILL.md, docs).
- **ADAPT** — touches JS/Py we already ported to Zig → port the *intent* into the named Zig file (do not re-introduce the JS).
- **SKIP** — npm packaging, i18n READMEs, sponsor/banner/waitlist/trendshift/star-history, ClawHub publish, upstream-only version bumps, marketing/author edits.
- **CONFLICT** — touches a file our rewrite changed or removed; needs manual reconciliation (decide fork-equivalent target).

## Table

| Commit | Subject | Class | Action | Target Zig file (or fork target) |
|--------|---------|-------|--------|----------------------------------|
| c4d1925 | Merge PR #323 hermes-plugin | SKIP | Merge of #323 Hermes plugin (root `__init__.py`/`plugin.yaml`/`after-install.md` + i18n README). Hermes is a third-party harness plugin, not Zig runtime. No fork value. | — |
| 6eb2b78 | Merge branch 'main' into salaamdev/main | SKIP | Integration merge; payload = already-listed PRs + i18n READMEs (#318/#321/#316/#313). No unique runtime change. | — |
| ac75159 | Merge branch 'main' into salaamdev/main | SKIP | Integration merge; payload = #253 mirrors + i18n + manifest bumps already covered by their PRs. | — |
| 8d154e6 | fix(benchmarks): strip block comments before counting LOC (#232) | ABSORB | Apply LOC block-comment strip + test to the JS benchmark (kept as JS). | `benchmarks/loc.js` (+ `benchmarks/loc.test.js`) — JS, not Zig |
| e353a1a | docs: add Swift/SwiftUI section to platform-native.md (#313) | ABSORB | Doc-only; fork has `docs/platform-native.md`. Add the Swift/SwiftUI section. | `docs/platform-native.md` (doc) |
| 7147937 | Sync ES/Korean READMEs with Devin CLI (#322) | SKIP | i18n README sync (depends on SKIPped #318 Devin + #283 Korean). | — |
| 33a4977 | fix(benchmark): reject --ollama-url without a host (#315) | ABSORB | Apply 2-line host-required guard to the Python benchmark (kept as Python). | `benchmarks/benchmark-local.py` (Python) |
| 7790c37 | Add Devin CLI plugin manifest (#318) | SKIP | New `.devin-plugin/plugin.json` + README; pulls in `scripts/check-versions.js` (absent in fork). Packaging/manifest, no runtime. | — |
| 203f5fd | Add Sponsors section / GreenPT (#321) | SKIP | README + sponsor SVGs. Marketing. | — |
| 64adbf9 | Announcement banner instead of badge (#316) | SKIP | README + waitlist banner PNGs. Marketing. | — |
| 7086abe | Make the waitlist teaser pop and translate it (#314) | SKIP | README waitlist teaser + i18n. Marketing. | — |
| 4e5f9cc | Add a waitlist teaser to the README (#312) | SKIP | README marketing teaser. | — |
| a945778 | docs: Star History chart to READMEs (#294) | SKIP | README badge/chart. Marketing. | — |
| 6cd0c42 | docs: Trendshift badges to READMEs (#293) | SKIP | README badges. Marketing. | — |
| 025da37 | release: 4.8.3 (#286) | SKIP | Upstream version bump across manifests incl. retired `ponytail-mcp/package.json`. Fork uses its own version scheme (`package.json` 0.1.0). | — |
| b9fa564 | feat: inject ponytail ruleset into subagents via SubagentStart hook (#254) | ADAPT | **High-value runtime feature.** Add a SubagentStart hook: (1) new `SubagentStart` branch in the **`.plain` host path** of `buildHookOutputFor` emitting `{"hookSpecificOutput":{hookEventName,additionalContext}}` (native Claude drops raw stdout for SubagentStart); the codex branch already carries hookSpecificOutput. (2) New entry point reading the live flag (`readMode`) → if active+non-off, `writeHookOutput("SubagentStart", mode, getInstructions(...))`. (3) Wire a `SubagentStart` block into `hooks/claude-codex-hooks.json` (+ `commandWindows`) invoking it via `bin/ponytail-launch`. | `zig/src/common.zig` (buildHookOutputFor + readMode helper) + **new** `zig/src/subagent.zig` (or reuse `activate.zig` with a mode flag) + `hooks/claude-codex-hooks.json` + `bin/ponytail-launch{,.ps1}` |
| 9d0118d | docs: Korean README translation (#283) | SKIP | New `README.ko.md`. i18n. | — |
| a0766a3 | docs: npm install + badge for OpenCode, drop symlink note (#285) | SKIP | README npm-install instructions (npm packaging path the fork doesn't ship). | — |
| 17e2773 | release: 4.8.2 (#284) | SKIP | Upstream version bump. Fork has own scheme; `ponytail-mcp/package.json` absent. | — |
| 7d303b7 | ci: publish via npm trusted publishing OIDC (#282) | SKIP | npm publish workflow. Fork ships Zig release archives, not npm. | — |
| e368c48 | feat: scope npm package as @dietrichgebert/ponytail (#280) | SKIP | npm scope rename (`package.json`/README/opencode shim string). Upstream npm packaging. | — |
| 17a4660 | feat: publish ponytail as installable npm package for OpenCode and Pi (#197) | SKIP | npm packaging + publish.yml. Touches `.opencode/plugins/ponytail.mjs` only for npm-resolve plumbing; the fork's mjs already execs the Zig `ponytail-instructions` binary, so the npm-package wiring is moot here. | — (opencode shim stays JS; no npm path) |
| 2b426c6 | fix: make shared hooks parse in PowerShell (#265) | CONFLICT | Upstream fixes `hooks/claude-codex-hooks.json` to a PowerShell-parseable `command`/`commandWindows` form for the **node** invocation. The fork's `claude-codex-hooks.json` already uses a **different** form (`bin/ponytail-launch` + `pwsh … ponytail-launch.ps1`), so the upstream hunk won't apply. Intent (Windows-safe hook invocation) is **already satisfied** by the fork's launcher form — verify `bin/ponytail-launch.ps1` covers SessionStart/UserPromptSubmit (and the new SubagentStart from #254). No code change unless the launcher shim is missing a path. | `hooks/claude-codex-hooks.json` + `bin/ponytail-launch.ps1` (reconcile, likely no-op) |
| 268be28 | docs: instructions for usage with Swival (#264) | ABSORB | Doc-only; add Swival section to README + `docs/agent-portability.md` (fork has the latter). README portion optional. | `docs/agent-portability.md` (doc) |
| c8b12b6 | fix(pi-extension): guard status bar render when ui has no theme (#279) | ABSORB | Follow-up to #275; null-guard `ctx.ui.theme`. pi-extension stays JS → apply directly. | `pi-extension/index.js` (+ `pi-extension/test/extension.test.js`) — JS |
| 947f2ff | feat(pi-extension): status bar indicator for ponytail mode (#275) | ABSORB | **Runtime feature** for Pi. pi-extension is JS by design → add `syncStatus` + `agent_start`/`agent_end` hooks directly. Confirmed absent in fork (`grep syncStatus` empty). | `pi-extension/index.js` — JS |
| 08f0daf | fix(benchmark): scheme validation to ollama-url (#274) | ABSORB | Apply scheme-validation to the Python benchmark (kept as Python). Pairs with #315. | `benchmarks/benchmark-local.py` (Python) |
| 7b21459 | 🧪 test for resolveSessionMode edge case (#268) | ABSORB | Test-only for the JS pi-extension helper (kept as JS). | `pi-extension/test/helpers.test.js` — JS |
| d82c68c | Update README with plugin installation steps (#272) | SKIP | README install steps (upstream npm/plugin flavor). | — |
| 6d5d75a | docs: clarify uninstall run-order + statusLine ceiling (#278) | ADAPT | Doc + tweak to `scripts/uninstall.js` (retired in fork). Capture the run-order/ceiling guidance in fork docs; uninstall behavior belongs in the Zig uninstall path (see #228). | fork docs + `zig/src/` uninstall path (see #228 row) |
| ae24cd0 | fix: add uninstall cleanup script for state outside plugin files (#228) | ADAPT | **Cleanup intent we want**, but the script is `scripts/uninstall.js` depending on retired `hooks/ponytail-config.js`. Port intent: remove `.ponytail-active` flag, the config file, and the `statusLine` entry it added to `settings.json`. Fork has **no** uninstall path today (grep confirmed). | **new** `zig/src/uninstall.zig` (or an `uninstall` subcommand) reusing `common.zig` flag/config/settings paths + `install.sh` uninstall hook |
| 8cff216 | fix: use --tags (not --tag) for clawhub skill publish (#277) | SKIP | ClawHub publish script flag fix. Fork doesn't publish to ClawHub. | — |
| 88be9ca | feat: add publish-openclaw-skills.js to push skills to ClawHub (#273) | SKIP | New ClawHub publish script. Out of scope for the Zig fork. | — |
| 763e04d | fix: align version manifests to 4.8.1 + drift guard (#270) | CONFLICT | Adds `scripts/check-versions.js` over a manifest set that includes the **retired** `ponytail-mcp/package.json` and an upstream version (4.8.1). Fork keeps `.claude-plugin/plugin.json` (4.7.0), `.codex-plugin/plugin.json`, `.github/plugin/plugin.json`, `gemini-extension.json`, `package.json` (0.1.0) but **not** `ponytail-mcp/package.json`. Drift-guard is worth having, but the file list and version must be fork-specific. Optional ADAPT later; not a runtime feature. | `scripts/check-versions.js` (fork-specific manifest list) — JS tooling, no Zig |
| dedc97c | fix: comprehension-first guard + reuse rung (#245, #217) (#253) | ABSORB | **High-value behavior change.** Fork SKILL.md is byte-identical to this commit's parent → apply the SKILL.md delta verbatim (new rung 2 "Already in this codebase? Reuse it", comprehension-first / root-cause-not-symptom guard). It flows to every binary automatically via `@embedFile("skill_md")` (no Zig code change). The JS `getFallbackInstructions` edit has **no Zig counterpart** — the fork embeds SKILL.md at comptime, so there is no disk-read fallback to patch. Also ABSORB the agentic-benchmark tasks (reuse-slug/reuse-money/trace-transfer/trace-amount + harness multi-file seed) into the Python benchmark, and the results writeup. | `skills/ponytail/SKILL.md` (verbatim) + `benchmarks/agentic/{run.py,tasks.py}` (Python) + `benchmarks/results/2026-06-22-issue-245-217-comprehension.md`. **No Zig edit** — embedded SKILL.md carries it. |
| 731d319 | Merge branch 'main' into main | SKIP | Integration merge; payload = OpenClaw skill mirrors + manifest bumps from constituent PRs. No unique runtime change. | — |
| b4f725f | Merge branch 'main' into main | SKIP | Integration merge; OpenClaw skill SKILL.md mirrors + manifest bumps. No unique runtime change. | — |
| ce55fd4 | Update author in plugin.yaml to Salaamdev | SKIP | Hermes `plugin.yaml` author edit. Third-party plugin metadata. | — |
| 4198fc3 | add Hermes plugin for Ponytail with command support and docs | SKIP | Hermes plugin scaffold (`__init__.py`/`plugin.yaml`/`after-install.md` + tests). Third-party harness, not Zig runtime. | — |

## Summary by class

- **ABSORB (8):** #232 (loc.js), #313 (Swift docs), #315 + #274 (benchmark-local.py ollama-url), #279 + #275 (pi-extension status bar, JS), #268 (pi helper test, JS), #264 (Swival doc), **#253** (SKILL.md behavior + agentic benchmark — flows via embedded SKILL.md, no Zig edit).
- **ADAPT (3):** **#254** SubagentStart → `common.zig` + new `subagent.zig` + `claude-codex-hooks.json` + launcher; **#228** uninstall cleanup → new `zig/src/uninstall.zig`; **#278** uninstall-doc/run-order → fork docs + the same Zig uninstall path.
- **CONFLICT (2):** #265 PowerShell hook parse (fork already uses launcher form — likely no-op, verify `ponytail-launch.ps1`); #270 version-drift guard (`check-versions.js` over a fork-specific manifest list, no retired `ponytail-mcp/package.json`).
- **SKIP (26):** all 4 integration merges (c4d1925, 6eb2b78, ac75159, 731d319, b4f725f → 5 merges), npm packaging (#197/#280/#282/#285/#284/#286/#272/#270-version-bumps), i18n READMEs (#283/#322), sponsor/banner/waitlist/trendshift/star-history (#321/#316/#314/#312/#294/#293), ClawHub publish (#273/#277), Hermes plugin (#323/4198fc3/ce55fd4), Devin manifest (#318).

## Top priority for the fork (runtime value)

1. **#254 SubagentStart** (ADAPT) — closes a real gap: Task-spawned subagents currently run ponytail-unaware. Needs the `.plain`-host `SubagentStart` JSON branch in `buildHookOutputFor` + a new entry point + manifest/launcher wiring.
2. **#253 comprehension-first + reuse rung** (ABSORB) — behavior win, conflict-free, single SKILL.md edit auto-propagates through `@embedFile`.
3. **#275 / #279 pi status bar** (ABSORB) — user-visible Pi feature, JS stays JS.
4. **#228 uninstall cleanup** (ADAPT) — fork has no uninstall path at all; port the flag/config/statusLine cleanup into Zig.
5. **Benchmark fixes #232 / #315 / #274** (ABSORB) — Python/JS benchmarks, direct apply.

## Notes / caveats

- This is **READ-ONLY analysis**. No merge, no cherry-pick, no upstream submission. The only write is this doc.
- #265 and #270 are tagged CONFLICT, not SKIP, because their *intent* matters but the upstream hunks won't apply cleanly to the rewritten/removed files — each needs a fork-specific decision, not a blind port.
- All line/file claims were validated against `origin/main`/`upstream/main` live state via `git show --stat` and targeted `grep`; no claim rests on docs alone.
