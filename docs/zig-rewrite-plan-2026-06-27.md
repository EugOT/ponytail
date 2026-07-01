# Ponytail Zig-Rewrite Surface Audit & Plan (2026-06-27)

Thread: `ponytail.surface.audit`. Read-only audit of the remaining JS/Python
surface, with the true minimal irreducible set of host-mandated shims and a
per-harness target form. Goal: drive the pure-Zig cutover without re-breaking the
pi/opencode chain the way the prior retirement did.

## 0. Baseline (validated against live state, not docs)

Measured on `origin/main` (`git fetch origin` → exit 0) by `git show <ref>:<file> | wc -l`:

| Language | Lines | How counted |
|----------|-------|-------------|
| JavaScript (`*.js`/`*.mjs`/`*.cjs`) | **2660** | all tracked files |
| Python (`*.py`) | **1473** | all tracked files |
| Zig (`zig/src/*.zig`) | **2377** | source only |
| Zig (`zig/src` + `zig/build.zig`) | 2579 | incl. build.zig (202) |

The task's "Zig 2377" is the `zig/src/*.zig` figure (excludes `build.zig`). All
three baselines reproduce exactly. Current working branch is `zig/r6-reconcile`
(HEAD `ef2d1d0`), whose Zig matches `origin/main` line-for-line.

Build evidence: `zig version` → `0.16.0`; `zig build -Dtool=ponytail` in a
sandboxed cache (`ZIG_LOCAL_CACHE_DIR=$(mktemp -d)`) → **exit 0**, emitting five
binaries: `ponytail-activate`, `ponytail-hook`, `ponytail-instructions`,
`ponytail-mcp`, `ponytail-statusline`.

---

## STEP 1 — Import graph & the true irreducible set

### 1.1 Edges (extracted with `ast-grep -p 'require($A)'` / `import` patterns)

Only the harness-loaded entry modules + their first-party chain are listed
(stdlib `fs`/`path`/`os`/`child_process` edges omitted).

```
pi-extension/index.js  (pi loads this as a JS extension module)
  ├─require→ hooks/ponytail-config.js
  │            └─require→ hooks/ponytail-fs-safe.js
  ├─require→ hooks/ponytail-instructions.js
  │            └─require→ hooks/ponytail-config.js  (shared)
  └─require→ hooks/ponytail-instructions-bin.js
               ├─require→ hooks/ponytail-instructions.js  (JS FALLBACK only)
               └─execFileSync→ zig/zig-out/bin/ponytail-instructions  ← ZIG

.opencode/plugins/ponytail.mjs  (opencode loads this as an ESM plugin module)
  ├─require→ hooks/ponytail-instructions-bin.js  (→ Zig binary, JS fallback)
  ├─require→ hooks/ponytail-config.js
  └─require→ hooks/ponytail-fs-safe.js
```

The four chain files and which harness loads them:

| File | Lines | Loaded by | Role |
|------|-------|-----------|------|
| `hooks/ponytail-config.js` | 124 | pi (direct), opencode (direct) | mode parse/normalize, `getDefaultMode`, `writeDefaultMode` (config.json) |
| `hooks/ponytail-fs-safe.js` | 181 | via config.js + opencode direct | `safeWriteFlag` symlink-safe atomic write |
| `hooks/ponytail-instructions.js` | 92 | pi (`filterSkillBodyForMode`), `-bin.js` fallback | JS ruleset builder + pure `filterSkillBodyForMode` helper |
| `hooks/ponytail-instructions-bin.js` | 79 | pi, opencode | exec bridge to the Zig `ponytail-instructions` binary, JS fallback inside |

### 1.2 What "irreducible" actually means here

A file is IRREDUCIBLE iff a JS-mandated harness (pi JS module, opencode ESM
module) imports it AND no Zig binary can serve the same role. The host mandate is
the *entry module* (`pi-extension/index.js`, `.opencode/plugins/ponytail.mjs`) —
pi/opencode load a JS/ESM module in-process; they do not exec an external binary
for the plugin object itself. Everything reachable from those entry modules is a
candidate for Zig replacement *if its work can be done out-of-process (exec a
binary) or removed*.

### 1.3 The instruction-building logic is ALREADY in Zig (proven, not assumed)

`hooks/ponytail-instructions-bin.js` already `execFileSync`s the
`ponytail-instructions` Zig binary and only falls back to
`ponytail-instructions.js` when the binary is absent. `zig/src/common.zig`
already exports the Zig equivalents of every JS-chain function
(`grep 'pub fn' zig/src/common.zig`): `getDefaultMode`, `getInstructions`,
`filterSkillBodyForMode`, `safeWriteFlag`, `isSymlink`, `classify`, `isValidMode`.

Differential check (sandboxed `ponytail-instructions` binary vs the JS builder,
per mode) — **byte-identical**:

```
mode=lite   : MATCH (len=4002)
mode=full   : MATCH (len=4029)
mode=ultra  : MATCH (len=4067)
mode=review : MATCH (len=81)
mode=off    : MATCH (len=0)
```

So `ponytail-instructions.js` (92) and the ruleset logic in `ponytail-config.js`
are **redundant** — the Zig binary covers them. They persist only as the
binary-absent fallback.

### 1.4 TRUE minimal irreducible set

This is the part the prior retirement got wrong: it treated the whole
`index.js → config.js → fs-safe.js → instructions.js → instructions-bin.js`
chain as one indivisible JS unit. It is not. Reducibility per node:

| Node | Reducible? | Why / target |
|------|-----------|--------------|
| `pi-extension/index.js` | **NO — irreducible** | pi mandates a JS extension module. Keep, but shrink to host glue only (command registration, lifecycle, session-entry mode resolution). |
| `.opencode/plugins/ponytail.mjs` | **NO — irreducible** | opencode mandates an ESM plugin module. Keep, shrink to host glue (config skill-path, `system.transform`, `command.execute.before`). |
| `hooks/ponytail-instructions-bin.js` | **NO — irreducible (thin)** | It is the exec bridge the two irreducible shims call to reach the Zig binary. Without it the shims would each need their own spawn logic. Keep as the one shared ~40-line spawn-or-fallback bridge. |
| `hooks/ponytail-instructions.js` | **YES — reducible to fallback-only** | Pure JS ruleset builder. The Zig binary supersedes it (1.3). Cannot be deleted while the bridge keeps a JS fallback, but it can shrink to *only* `filterSkillBodyForMode` + `getFallbackInstructions` (the parts the binary-absent path and pi's direct `filterSkillBodyForMode` import need). |
| `hooks/ponytail-config.js` | **PARTIALLY reducible** | The *ruleset* parts (mode→instructions) are Zig-served. But `getDefaultMode`/`writeDefaultMode`/`normalize*`/`isDeactivationCommand` are called **synchronously, in-process** by pi (session-entry mode resolution, `/ponytail default` write) and opencode (`readMode`/`writeMode` per turn). pi/opencode cannot exec a binary mid-turn for a same-process boolean. **Irreducible as in-process JS** unless those reads/writes move out-of-process (see Option B). |
| `hooks/ponytail-fs-safe.js` | Same as config.js | `safeWriteFlag` is called in-process by opencode's `writeMode` and by config.js's `writeDefaultMode`. Irreducible as in-process JS while those writers stay in JS. |

**Minimal irreducible JS for pi + opencode = the 2 entry shims + the
instructions-bin bridge + the in-process config/fs-safe pair.** That is
`index.js` + `ponytail.mjs` + `instructions-bin.js` + `ponytail-config.js` +
`ponytail-fs-safe.js`. `ponytail-instructions.js` collapses to a fallback stub.

NB: Claude Code, Codex, and Copilot are ALREADY pure-Zig — their hook maps
(`hooks/claude-codex-hooks.json`, `hooks/copilot-hooks.json`) invoke
`bin/ponytail-launch ponytail-activate|ponytail-hook` (a shell launcher that
resolves and execs the Zig binary). No Node on those paths. The JS chain above
matters ONLY for pi and opencode.

### 1.5 Two ways to shrink the irreducible config/fs-safe pair

- **Option A (low risk, recommended first):** leave `ponytail-config.js` +
  `ponytail-fs-safe.js` as thin in-process JS, but make `ponytail-instructions.js`
  a fallback-only stub. Net: deletes ~0 files but removes the *duplicate ruleset
  logic*; the only JS that runs on the hot path is host glue + a 40-line bridge +
  config/fs-safe. This is the safe, prior-break-proof end state.
- **Option B (full purity, higher risk):** add a `ponytail-config` CLI verb to a
  Zig binary (`ponytail-config get-default` → prints mode; `ponytail-config
  set-default <mode>` → writes config.json via `common.safeWriteFlag`; `ponytail-
  config write-mode <path> <mode>` for opencode's flag). Then `ponytail-config.js`
  and `ponytail-fs-safe.js` shrink to ~10-line exec wrappers (spawn the binary,
  parse one line) with a JS fallback. opencode's per-turn `readMode` would shell
  out — acceptable (it already shells out for instructions every turn). Only do
  Option B after Option A ships and the differential tests are green, to avoid
  re-introducing a chain break.

---

## STEP 2 — Benchmark / tooling classification (Py 1473 + bench JS)

All benchmark code is **TOOLING**: dev/CI-time measurement, never shipped to a
user's agent. It calls models via stdlib HTTP (`urllib.request` to the Anthropic
Messages API / Ollama `/api/chat`) or `subprocess` to the `claude` CLI — **no
SDK dependency** (`anthropic`/`openai` appear only as the API URL string and the
`x-api-key` header in `judge.py`). That makes them genuine Zig candidates (Zig
std HTTP client + subprocess), but they are the *lowest* priority: they never run
in the distributed product and porting buys no user-facing purity.

### Python (1473)

| File | Lines | What it does | Externals | Zig-port effort |
|------|-------|-------------|-----------|-----------------|
| `benchmarks/agentic/tasks.py` | 570 | Task table: seeded workspaces + deterministic scorers | stdlib only (`pathlib`) | **Large.** Mostly data; port is a Zig data module + scorer fns. Low value. |
| `benchmarks/agentic/run.py` | 408 | Runs (task×arm×model) through headless `claude` CLI in temp workspaces, scores | `subprocess`, `concurrent.futures` | **Large.** Subprocess orchestration + parallelism; Zig `std.process` + thread pool. Moderate value (CI). |
| `benchmarks/agentic/judge.py` | 185 | LLM-judge over-engineering pass via Anthropic Messages API | `urllib.request` | **Medium.** One HTTP POST + JSON parse. Zig `std.http.Client`. |
| `benchmarks/agentic/complete.py` | 154 | LLM-judge completeness pass; reuses judge.py | imports judge.py | **Medium.** Same shape as judge. |
| `benchmarks/benchmark-local.py` | 156 | Ollama local bench (baseline vs caveman vs ponytail), LOC + wall-clock | `urllib.request` | **Medium.** HTTP + table print. |

### Benchmark JS (subset of the 2660)

| File | Lines | What it does | Zig-port effort |
|------|-------|-------------|-----------------|
| `benchmarks/robustness-audit.js` | 205 | Edge-case trap harness; `--selftest` proves checks before API spend | **Medium** (string checks + py/node spawn) |
| `benchmarks/correctness.js` | 281 | Runs generated code against per-task asserts | **Large** (spawns python/node, extracts code) |
| `benchmarks/behavior.js` | 58 | Behavior-gate probes over the ruleset | **Small** |
| `benchmarks/claude-email.js` / `model-email.js` | 40 / 39 | Email-task rate, baseline vs ponytail | **Small** (import robustness-audit) |
| `benchmarks/loc.js` | 13 | Non-blank/non-comment LOC metric | **Trivial** |
| `benchmarks/generate-examples.mjs` | 63 | Regenerate `examples/*.md` from a real run | **Small** |
| `benchmarks/arms/*.js` | 18 total | Three one-line arm prompts | **Trivial** |

**Recommendation:** classify the whole benchmark tree as *keep-as-is tooling*.
Port only if/when a benchmark binary is wanted for hermetic CI; even then,
`loc.js`/`arms/*` and the LLM-judge HTTP scripts are the only high-ratio targets.
The non-benchmark scripts `scripts/build-openclaw-skills.js` (60) and
`scripts/check-rule-copies.js` (74) are build/lint tooling in the same bucket
(small, stdlib-only) — fold them into a Zig `ponytail-build` verb opportunistically.

---

## STEP 3 — Per-harness table: today → target pure-Zig form

| Harness | How ponytail reaches it TODAY | Target pure-Zig form |
|---------|-------------------------------|----------------------|
| **Claude Code** | `.claude-plugin/plugin.json` → `hooks/claude-codex-hooks.json` → `bin/ponytail-launch ponytail-{activate,hook}` (shell launcher execs Zig binary) + `skills/` + `commands/` | **ALREADY pure-Zig.** Launcher is host-automation shell, not app logic. No change. |
| **Codex** | `.codex-plugin/plugin.json` → same `claude-codex-hooks.json` → `ponytail-launch` Zig binaries + `skills/` | **ALREADY pure-Zig.** No change. |
| **Copilot** | `hooks/copilot-hooks.json` → `bin/ponytail-launch ponytail-{activate,hook}` + `.github/copilot-instructions.md` | **ALREADY pure-Zig** for hooks. Instruction file is static text. No change. |
| **opencode** | `.opencode/plugins/ponytail.mjs` (ESM module) → exec `ponytail-instructions` (Zig) for body; in-process JS `config.js`+`fs-safe.js` for mode read/write | **ESM shim irreducible** (host mandates ESM module). Target: shim keeps only `config`/`system.transform`/`command.execute.before` glue; ruleset already Zig; Option B moves `readMode`/`writeMode` to a `ponytail-config` Zig verb so the only JS is the host-required module skeleton + spawn calls. |
| **pi** | `pi-extension/index.js` (JS module) → exec `ponytail-instructions` (Zig) for body; in-process JS for command parse + session mode resolution | **JS shim irreducible** (host mandates JS extension module). Target: shrink `index.js` to command registration + lifecycle + `resolveSessionMode`; `instructions.js` → fallback stub; Option B moves `getDefaultMode`/`writeDefaultMode` to the Zig verb. |
| **OpenClaw** | `scripts/build-openclaw-skills.js` (60) generates `.openclaw/skills/*/SKILL.md` (rewritten frontmatter, verbatim body); committed copies checked by `tests/openclaw-skills.test.js` | Port to a Zig `ponytail-openclaw` verb (or fold into instructions binary): emit `SKILL.md` with single-line `description` frontmatter + verbatim body. Caveman already has `zig/src/openclaw.zig` as the reference (marker-fenced SOUL.md append + frontmatter merge). **Small port, clean win** — removes the only OpenClaw JS. |
| **pz** *(NEW — not yet present in ponytail)* | Nothing today. No `.pz/` adapter exists. | **New Zig instructions binary emits `.pz/skills/ponytail/SKILL.md` — no JS shim** (see §3.1). Cleaner than pi/opencode because pz loads skills by *scanning files*, not by loading a host module. |

### 3.1 pz-extension design (pure-Zig, no shim)

pz's loader was read from source (`/Users/etretiakov/ghq/github.com/EugOT/pz/src/core/skill.zig`):

- **Global skills:** `~/.pz/skills/*/SKILL.md` (`skill.zig:186`).
- **Project skills:** `./.pz/skills/*/SKILL.md` relative to cwd (`skill.zig:197`).
- **Frontmatter keys parsed** (`skill.zig:89-101`): exactly `name`, `description`,
  `disable_model_invocation`, `user_invocable`. **There is no `always: true`**
  (unlike NullClaw). A pz skill is *model-invocable by default* — discovered and
  offered to the model when relevant, NOT force-injected every turn.
- **Always-on context** on pz comes from a separate channel: `AGENTS.md`
  (`~/.pz/AGENTS.md` global, project `./AGENTS.md`) loaded by
  `src/core/context.zig` and gated by the policy allow-list (`policy.zig:121`).

Design — a Zig verb (e.g. `ponytail-init --pz` or a `ponytail-pz` binary,
modeled on caveman's `zig/src/nullclaw.zig`):

1. **Skill discovery file:** write `./.pz/skills/ponytail/SKILL.md` (and/or the
   `~/.pz/skills/` global variant) with frontmatter
   `name: ponytail`, `description: <single-line picker desc>`,
   `user_invocable: true`, and the verbatim ruleset body from
   `skills/ponytail/SKILL.md`. This gives pz a *first-class ponytail skill the
   user can `/ponytail`-invoke and the model can auto-pick*.
2. **Always-on (optional):** if the user wants ponytail active every turn on pz,
   also append the compact ruleset to `AGENTS.md` (marker-fenced, idempotent —
   caveman's `openclaw.zig` SOUL.md append is the exact pattern). Honest framing:
   the SKILL.md alone is *discovery*; AGENTS.md is what makes it *always-on*.
3. **No JS/ESM shim** — pz never loads a host module for skills; it scans the
   filesystem. So the entire pz adapter is file emission a Zig binary already
   does safely (`common.safeWriteFlag` + symlink-refuse + `mkdir 0700`). This is
   strictly cleaner than the pi/opencode adapters, which are irreducible JS.

Reuse: `zig/src/common.zig` (`safeWriteFlag`, `classify`, `isSymlink`,
`ancestorUnsafe`) + the caveman `nullclaw.zig`/`openclaw.zig` install/uninstall
shape (workspace resolve → symlink-safe `mkdir -p` → frontmatter merge → atomic
write → idempotent re-run). Add an uninstall that removes only `.pz/skills/ponytail/`
and strips the AGENTS.md marker block.

---

## Sequenced plan (lowest-risk-first, prior-break-proof)

1. **Lock the differential gate first.** Keep/extend a test that asserts the Zig
   `ponytail-instructions` binary == the JS builder for every mode (the 5-mode
   check above). This is the guardrail that makes every later JS shrink safe.
2. **Shrink `ponytail-instructions.js` to fallback-only** (Option A). No file
   deleted, duplicate ruleset logic removed. pi/opencode unaffected (they already
   route through the binary).
3. **Port OpenClaw generator to Zig** (`scripts/build-openclaw-skills.js` → Zig
   verb). Update `tests/openclaw-skills.test.js` to invoke the binary. Removes
   the only non-shim OpenClaw JS.
4. **Add the pz adapter** (§3.1) — net-new pure-Zig, no regression risk.
5. **Option B (optional, last):** add a `ponytail-config` Zig verb and collapse
   `ponytail-config.js`/`ponytail-fs-safe.js` to exec wrappers. Only after 1-4
   are green, because this is the chain that broke before.
6. **Benchmarks:** leave as tooling. Port `loc.js`/`arms/*`/judge-HTTP only if a
   hermetic-CI benchmark binary is later wanted.

### Do-not-repeat (prior break root cause)

The earlier retirement deleted/rerouted the chain as a unit and broke
`index.js → config.js → fs-safe.js → instructions.js → instructions-bin.js`.
The fix discipline: the two host-mandated shims (`index.js`, `ponytail.mjs`) and
their in-process `config`/`fs-safe` reads are irreducible **as JS**; only the
*ruleset logic* is Zig-served. Never delete `config.js`/`fs-safe.js` before a Zig
`ponytail-config` verb + its JS exec-wrapper + a green differential test exist.

---

## Evidence log (commands + exit codes)

- `git fetch origin` → exit 0.
- `git show origin/main:<f> | wc -l` summed → JS 2660, Py 1473, Zig src 2377 (build.zig +202 = 2579). All reproduce.
- `ast-grep --version` → `0.44.0`; require/import edges extracted with `ast-grep -p 'require($A)'` and `import` patterns (§1.1).
- `zig version` → `0.16.0`; `zig build -Dtool=ponytail` (sandboxed `ZIG_LOCAL_CACHE_DIR`) → exit 0, 5 binaries emitted.
- Differential `ponytail-instructions` (sandbox binary) vs `hooks/ponytail-instructions.js` → MATCH for lite/full/ultra/review/off.
- `ziglint zig/src/instructions.zig zig/src/common.zig` → exit 0; findings are stylistic only (Z006 constant-naming, Z024 line-length, Z015 private-error-set exposure) — pre-existing, not blockers.
- pz loader contract read from `/Users/etretiakov/ghq/github.com/EugOT/pz/src/core/skill.zig` (paths, frontmatter keys) and `src/core/context.zig` (AGENTS.md always-on).
- No install scripts were sourced or run against the real environment.
