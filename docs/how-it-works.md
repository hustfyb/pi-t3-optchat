# How pi-t3 works

## 1. When the shim injects anything

The wrapper only acts on real T3 RPC sessions. Every decision is a pure function of argv and the environment, and every skip is recorded in `~/.optchat/t3-bindings.log`.

| Gate | Condition | Result |
|---|---|---|
| RPC | `--mode rpc` or `--mode=rpc` present | else passthrough (`not-rpc`) |
| T3 | `T3_PI_MCP_EXTENSION_PATH` set (T3 always sets it) | else passthrough (`no-t3-mcp-env`) |
| user choice | no `--optchat-profile` in argv | else passthrough (`user-profile`) |
| CLI flags | no `--print/--resume/--export/--no-session/--fork/--help/--version` | else passthrough (`blocked-flag:…`) |
| kill switch | `~/.optchat/t3-off` absent | else skip (`t3-off`) |
| config | `OPTCHAT_T3_AUTOBIND` ≠ `0` | else skip (`disabled`) |
| installed | `settings.json` lists `"npm:pi-optchat"` and the source exists | else passthrough (`optchat-not-installed`) |
| patched | `pi-t3-patch-optchat --check` exits 0 | else passthrough (`optchat-unpatched`) |

`OPTCHAT_T3_REQUIRE_PATCH=0` turns the last gate into a warning, which is what the test suite uses.

## 2. Finding an existing binding

OptChat writes a session entry when it binds a profile:

```json
{"type":"custom","customType":"optchat.profile","data":{"name":"t3-fyb-fec815"}}
```

The wrapper scans the session directory for the current cwd:

```text
$PI_CODING_AGENT_SESSION_DIR/--<encoded cwd>--/*.jsonl
```

`<encoded cwd>` mirrors Pi's own encoding: strip a leading `/` or `\`, then replace `/`, `\` and `:` with `-` (so `/Users/me/fyb` → `Users-me-fyb`). An explicit `--session <path>` overrides the directory scan.

The **last** matching entry in the newest file wins, so a `/optchat profile x` switch is respected. If a binding is found, the profile is repaired (see §4) and nothing is injected — OptChat reads the binding from the session itself.

## 3. Minting a profile

When no binding exists:

1. `slug` = basename of cwd, lowercased, non-alphanumerics collapsed to `-`, last 16 chars.
2. Name = `t3-<slug>-<6 hex chars>`; up to 30 attempts to avoid collisions.
3. `~/.optchat/profiles` is created with mode `700`.
4. `config.json` is written atomically (`umask 077`, temp file + `rename`, mode `600`) from, in order:
   - `OPTCHAT_T3_SEED` (a profile directory or a config file),
   - `PI_T3_TEMPLATE` / `~/.local/share/pi-t3/profile-template.json`,
   - Pi's own `defaultProvider` / `defaultModel` / `defaultThinkingLevel` from `settings.json`.
   
   A source is accepted only when both `compactor` and `subagent` carry a non-empty `provider`, `model` and a valid `thinking` level; `main` is always stripped here, because OptChat owns that slot at runtime.
5. `AGENTS.md` (mode `600`) is created with a one-line placeholder.
6. `--optchat-profile <name>` is inserted **before** a bare `--` if present, otherwise appended, then the real Pi is `exec`'d with the modified argv.

## 4. Repair, without losing data

Repair runs only for profiles whose name starts with `t3-` and matches `^[a-z0-9][a-z0-9_-]{0,63}$`.

| State | Action | Log |
|---|---|---|
| `compactor` + `subagent` valid, `main` valid or absent | keep everything; recreate `AGENTS.md` if missing | `repaired-instructions` |
| `compactor` + `subagent` valid, `main` malformed | drop `main` in place (atomic rewrite) | `repaired-config  removed invalid main` |
| `compactor`/`subagent` broken, lock free | `mv <profile> <profile>.bad.<YYYYmmdd-HHMMSS>`, then mint a fresh one with the same name | `repaired-config  moved-to=…` + `repaired-profile` |
| `compactor`/`subagent` broken, lock socket served by a live process | leave it alone | `skip-repair  profile-locked` |

Two details matter in practice:

- **A legitimate `main` must survive.** OptChat writes `main` into `config.json` during normal operation. Treating that as corruption would move away a perfectly good profile (and its `AGENTS.md`) on every start.
- **A busy profile must not be moved.** `lock.sock` is a UNIX socket; the wrapper connects with a 1s timeout and treats `ECONNREFUSED`/`ENOENT` as stale, anything else as live.

## 5. The OptChat patch

`pi-optchat`'s connect path assumes a profile lock can only be owned by *another* process. T3's extension host re-opens the same profile inside the same process, so the busy check fires against itself and the thread never starts.

`pi-t3-patch-optchat` matches four exact anchors and rewrites them:

| Anchor | Change |
|---|---|
| A | skip the open entirely when `active?.name === name` or the same name is already opening; remember `openingName` |
| B | clear `openingName` on failure; if the busy owner line contains `· PID <own pid> ·`, treat it as success |
| C | declare `let openingName: string \| undefined` next to `required` |
| D | clear `openingName` once the binding is appended |

Every rewritten region carries the marker `optchat.t3-selflock-guard v1`, and patching is refused (`exit 3`) unless all four anchors matched exactly once. The original is kept at `src/index.ts.pre-t3patch`, so `--revert` restores the upstream bytes.

`--check` exit codes: `0` patched, `2` patchable, `3` unsupported/inconsistent shape, `4` source not found.

## 6. node on PATH

T3 spawns providers from its background service, which does not inherit an interactive shell's PATH — with fnm/nvm/volta, `node` is often missing and Pi cannot start at all. Before `exec`, the wrapper looks for `node` in the usual version-manager locations and prepends its directory to PATH when found. `PI_T3_REAL` and `PI_T3_TEMPLATE` make all of this testable in a sandbox.

## 7. Log format

`~/.optchat/t3-bindings.log`, tab separated:

```text
2026-10-29T12:00:18+0800	minted	reason=new-t3-thread	cwd=/Users/me/fyb	name=t3-fyb-fec815
2026-10-29T12:01:25+0800	no-inject-bound	reason=session already has optchat.profile	cwd=/Users/me/fyb	name=t3-fyb-fec815
```

Actions: `minted`, `invoke`, `no-inject-bound`, `repaired-config`, `repaired-instructions`, `repaired-profile`, `skip-*`, `passthrough` (only with `OPTCHAT_T3_DEBUG=1`).
