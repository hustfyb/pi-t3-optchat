#!/usr/bin/env bash
# smoke.sh — end-to-end tests for pi-t3 in a throwaway sandbox.
#
# Runs the real wrapper, doctor and patch script against a fake Pi binary, a
# fake pi-optchat source, fake T3 settings and a fake OPTCHAT_HOME. Nothing
# outside the sandbox is touched.
#
#   tests/smoke.sh            run all tests
#   KEEP=1 tests/smoke.sh     keep the sandbox for inspection
#
# License: MIT. See LICENSE.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd -P)"
SB="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pi-t3-smoke.XXXXXX")" >/dev/null 2>&1 && pwd -P)"
PASS=0
FAIL=0
FAILED_NAMES=""

cleanup() {
  if [ "${KEEP:-0}" = "1" ]; then
    printf '\nsandbox kept: %s\n' "$SB"
  else
    rm -rf "$SB"
  fi
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_NAMES="$FAILED_NAMES\n    - $1"; printf '  FAIL  %s\n' "$1"; }
section() { printf '\n%s\n' "$1"; }

assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected [$3], got [$2])"; fi
}
assert_contains() {
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing [$3])" ;; esac
}
assert_file() {
  if [ -f "$2" ]; then pass "$1"; else fail "$1 (missing $2)"; fi
}

# ---------------------------------------------------------------- sandbox ----
AGENT_DIR="$SB/agent"
OPTCHAT="$SB/optchat"
SESSIONS="$SB/sessions"
FAKE_SRC="$AGENT_DIR/npm/node_modules/pi-optchat/src/index.ts"
STUB_PI="$SB/bin/pi"
T3_SETTINGS="$SB/t3-settings.json"
TEMPLATE="$SB/template.json"
PROJECT="$SB/project"
PATCHER="$REPO_DIR/bin/pi-t3-patch-optchat"

mkdir -p "$(dirname "$FAKE_SRC")" "$(dirname "$STUB_PI")" "$OPTCHAT" "$SESSIONS" "$PROJECT" "$SB/home"

cat > "$STUB_PI" <<'EOF'
#!/usr/bin/env bash
printf 'REAL_PI'
for arg in "$@"; do printf ' |%s' "$arg"; done
printf '\n'
EOF
chmod +x "$STUB_PI"

printf '{"version":"0.10.1"}\n' > "$(dirname "$(dirname "$FAKE_SRC")")/package.json"

# Pi settings: package marker (wrapper gate) plus a default model that the
# wrapper falls back to when the template is unusable.
cat > "$AGENT_DIR/settings.json" <<'EOF'
{
  "packages": ["npm:pi-optchat"],
  "defaultProvider": "acme",
  "defaultModel": "acme/big-model",
  "defaultThinkingLevel": "high"
}
EOF

cat > "$TEMPLATE" <<'EOF'
{
  "compactor": {"provider": "acme", "model": "acme/small-model", "thinking": "medium"},
  "subagent": {"provider": "acme", "model": "acme/big-model", "thinking": "high"}
}
EOF

cat > "$T3_SETTINGS" <<EOF
{
  "providerInstances": {
    "pi": {
      "enabled": true,
      "config": {
        "binaryPath": "$REPO_DIR/bin/pi-t3",
        "launchArgs": ""
      }
    }
  }
}
EOF

# Upstream pi-optchat source shape (pre-patch). Indentation matters: the patcher
# matches these anchors byte for byte.
cat > "$SB/optchat-upstream.ts" <<'EOF'
// fixture: the shape pi-optchat 0.10.1 uses for profile connect/join
function connect(name: string, connect: string, ctx: unknown) {
  let joined;
  let openingName: string | undefined;
  const required = () => 1;
  async function loop() {
      for (;;) {
        if (!name) { status(ctx); return; }
        try {
          if (connect === 'join') joined = await joinProfile(name);
          else await openProfile(name, ctx);
          break;
        } catch (error) {
          if (error instanceof ProfileBusyError && connect === 'auto') { joined = await joinProfile(name); break; }
        }
      }
  }
}

function record(name: string, boundName: string) {
      if (name !== boundName) pi.appendEntry(binding, { name });
}
EOF

# Patched copy at the "installed" path, so wrapper and doctor see a healthy
# install by default.
cp "$SB/optchat-upstream.ts" "$SB/optchat.ts"
if ! PI_OPTCHAT_SRC="$SB/optchat.ts" bash "$PATCHER" --apply >"$SB/apply.log" 2>&1; then
  printf 'fixture setup failed:\n' >&2
  cat "$SB/apply.log" >&2
  exit 1
fi
cp "$SB/optchat.ts" "$FAKE_SRC"
cp "$SB/optchat-upstream.ts" "$SB/optchat-unpatched.ts"

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

encoded_cwd() { printf '%s' "$1" | sed 's|^[/\\]||; s|[/\\:]|-|g'; }

# run_wrapper [ENV=value...] -- <wrapper args...>
run_wrapper() {
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  ( cd "$PROJECT" && env -i \
      HOME="$SB/home" \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" \
      PI_CODING_AGENT_DIR="$AGENT_DIR" \
      OPTCHAT_HOME="$OPTCHAT" \
      PI_CODING_AGENT_SESSION_DIR="$SESSIONS" \
      PI_T3_REAL="$STUB_PI" \
      PI_T3_TEMPLATE="$TEMPLATE" \
      T3_PI_MCP_EXTENSION_PATH="$SB/fake-mcp.js" \
      PI_T3_DRY_RUN=1 \
      OPTCHAT_T3_REQUIRE_PATCH=0 \
      ${envs[@]+"${envs[@]}"} \
      "$REPO_DIR/bin/pi-t3" "$@" 2>&1 )
}

run_doctor() {
  ( cd "$PROJECT" && env -i \
      HOME="$SB/home" \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" \
      PI_CODING_AGENT_DIR="$AGENT_DIR" \
      OPTCHAT_HOME="$OPTCHAT" \
      PI_CODING_AGENT_SESSION_DIR="$SESSIONS" \
      PI_T3_TEMPLATE="$TEMPLATE" \
      T3_SETTINGS="$T3_SETTINGS" \
      bash "$REPO_DIR/bin/pi-t3-doctor" "$@" 2>&1 )
}

bind_session() {
  local name="$1" dir
  dir="$SESSIONS/--$(encoded_cwd "$(cd "$PROJECT" && pwd -P)")--"
  mkdir -p "$dir"
  printf '{"type":"custom","customType":"optchat.profile","data":{"name":"%s"}}\n' "$name" > "$dir/session.jsonl"
}

# --------------------------------------------------------------- wrapper ----
section 'passthrough decisions'

out="$(run_wrapper -- --mode rpc --version)"
assert_contains 'non-RPC flag passes through' "$out" 'reason=blocked-flag:--version'
assert_contains 'passthrough names the real binary' "$out" "real=$STUB_PI"

out="$(run_wrapper -- --mode json)"
assert_contains 'non-rpc mode passes through' "$out" 'reason=not-rpc'

out="$(run_wrapper T3_PI_MCP_EXTENSION_PATH= -- --mode rpc)"
assert_contains 'missing T3 MCP env skips injection' "$out" 'reason=no-t3-mcp-env'

out="$(run_wrapper -- --mode rpc --optchat-profile mine)"
assert_contains 'explicit user profile is respected' "$out" 'reason=user-profile'

out="$(run_wrapper -- --mode rpc --print hi)"
assert_contains 'print mode is not intercepted' "$out" 'reason=blocked-flag:--print'

out="$(run_wrapper OPTCHAT_T3_AUTOBIND=0 -- --mode rpc)"
assert_contains 'autobind can be disabled by env' "$out" 'reason=disabled'

touch "$OPTCHAT/t3-off"
out="$(run_wrapper -- --mode rpc)"
assert_contains 'kill switch t3-off is honoured' "$out" 'reason=t3-off'
rm -f "$OPTCHAT/t3-off"

section 'profile minting'

out="$(run_wrapper -- --mode rpc)"
minted="$(printf '%s\n' "$out" | sed -n 's/.*name=\([^ ]*\).*/\1/p' | head -1)"
case "$minted" in
  t3-project-*) pass "mints a profile named for the cwd ($minted)" ;;
  *) fail "mints a profile named for the cwd (got [$minted])" ;;
esac
assert_contains 'injects --optchat-profile into the real argv' "$out" "--optchat-profile $minted"
assert_file 'creates config.json' "$OPTCHAT/profiles/$minted/config.json"
assert_file 'creates AGENTS.md' "$OPTCHAT/profiles/$minted/AGENTS.md"
assert_eq 'config uses the template model' \
  "$(jq -r '.compactor.model' "$OPTCHAT/profiles/$minted/config.json")" 'acme/small-model'
assert_eq 'new profiles carry no main slot' \
  "$(jq -r 'has("main")' "$OPTCHAT/profiles/$minted/config.json")" 'false'
assert_eq 'config.json is mode 600' "$(file_mode "$OPTCHAT/profiles/$minted/config.json")" '600'
assert_contains 'mint is recorded in the log' "$(cat "$OPTCHAT/t3-bindings.log")" 'minted'

section 'binding reuse'

bind_session "$minted"
out="$(run_wrapper -- --mode rpc)"
assert_contains 'a bound session is not re-minted' "$out" 'reason=existing-binding'
assert_eq 'profile count is unchanged' "$(ls "$OPTCHAT/profiles" | wc -l | tr -d ' ')" '1'

section 'repair keeps working data'

# 1. legitimate `main` (OptChat writes it at runtime) + missing AGENTS.md
jq '. + {main:{provider:"acme",model:"acme/big-model",thinking:"high"}}' \
  "$OPTCHAT/profiles/$minted/config.json" > "$SB/c.json"
mv "$SB/c.json" "$OPTCHAT/profiles/$minted/config.json"
rm -f "$OPTCHAT/profiles/$minted/AGENTS.md"
out="$(run_wrapper -- --mode rpc)"
assert_file 'missing AGENTS.md is recreated in place' "$OPTCHAT/profiles/$minted/AGENTS.md"
assert_eq 'legitimate main survives repair' \
  "$(jq -r '.main.model' "$OPTCHAT/profiles/$minted/config.json")" 'acme/big-model'
assert_contains 'recreation is logged' "$(cat "$OPTCHAT/t3-bindings.log")" 'recreated AGENTS.md'

# 2. malformed main is stripped; the rest of the profile is preserved
jq '.main = {"provider":123}' "$OPTCHAT/profiles/$minted/config.json" > "$SB/c.json"
mv "$SB/c.json" "$OPTCHAT/profiles/$minted/config.json"
out="$(run_wrapper -- --mode rpc)"
assert_eq 'malformed main is dropped' \
  "$(jq -r 'has("main")' "$OPTCHAT/profiles/$minted/config.json")" 'false'
assert_eq 'compactor survives the strip' \
  "$(jq -r '.compactor.provider' "$OPTCHAT/profiles/$minted/config.json")" 'acme'

# 3. genuinely broken compactor/subagent -> profile moved aside and re-minted
printf '{"compactor":{},"subagent":{}}\n' > "$OPTCHAT/profiles/$minted/config.json"
out="$(run_wrapper -- --mode rpc)"
assert_eq 'broken profile is replaced' \
  "$(jq -r '.compactor.provider' "$OPTCHAT/profiles/$minted/config.json")" 'acme'
bad_count="$(find "$OPTCHAT/profiles" -maxdepth 1 -name "$minted.bad.*" | wc -l | tr -d ' ')"
assert_eq 'broken profile is preserved as .bad.*' "$bad_count" '1'

section 'patch script'

check="$(PI_OPTCHAT_SRC="$SB/optchat-unpatched.ts" bash "$PATCHER" --check 2>&1)"; code=$?
assert_eq 'unpatched upstream reports exit 2' "$code" '2'
assert_contains 'check names the patchable state' "$check" 'patchable'

check="$(PI_OPTCHAT_SRC="$SB/optchat.ts" bash "$PATCHER" --check 2>&1)"; code=$?
assert_eq 'patched source reports exit 0' "$code" '0'

assert_eq 'guard markers are present' \
  "$(grep -c 'optchat.t3-selflock-guard v1' "$SB/optchat.ts")" '2'
assert_eq 'patch adds the same-PID guard' \
  "$(grep -c 'error.owner.includes' "$SB/optchat.ts")" '1'
assert_eq 'patch backfills openingName' \
  "$(grep -c 'openingName = undefined' "$SB/optchat.ts")" '2'

cp "$SB/optchat-upstream.ts" "$SB/revert.ts"
apply="$(PI_OPTCHAT_SRC="$SB/revert.ts" bash "$PATCHER" --apply 2>&1)"; code=$?
assert_eq 'apply exits 0' "$code" '0'
assert_contains 'apply reports the backup path' "$apply" '.pre-t3patch'
PI_OPTCHAT_SRC="$SB/revert.ts" bash "$PATCHER" --revert >/dev/null 2>&1
if diff -q "$SB/optchat-upstream.ts" "$SB/revert.ts" >/dev/null 2>&1; then
  pass 'revert restores the original bytes'
else
  fail 'revert restores the original bytes'
fi

printf 'export const unrelated = 1;\n' > "$SB/optchat-bad.ts"
check="$(PI_OPTCHAT_SRC="$SB/optchat-bad.ts" bash "$PATCHER" --check 2>&1)"; code=$?
assert_eq 'unknown upstream shape is refused' "$code" '3'

check="$(PI_OPTCHAT_SRC="$SB/nope.ts" bash "$PATCHER" --check 2>&1)"; code=$?
assert_eq 'missing source reports exit 4' "$code" '4'

section 'patch gate'

out="$(run_wrapper OPTCHAT_T3_REQUIRE_PATCH=1 PI_OPTCHAT_SRC="$SB/optchat-unpatched.ts" -- --mode rpc)"
assert_contains 'unpatched optchat blocks injection by default' "$out" 'reason=optchat-unpatched'

out="$(run_wrapper OPTCHAT_T3_REQUIRE_PATCH=1 PI_OPTCHAT_SRC="$SB/optchat.ts" -- --mode rpc)"
assert_contains 'patched optchat is injected normally' "$out" 'reason=existing-binding'

out="$(run_wrapper PI_CODING_AGENT_DIR="$SB/empty-agent" -- --mode rpc)"
assert_contains 'no installed optchat passes through' "$out" 'reason=optchat-not-installed'

section 'doctor'

out="$(run_doctor)"; code=$?
assert_eq 'doctor exits 0 on a healthy install' "$code" '0'
assert_contains 'doctor reports the wrapper path' "$out" "path: $REPO_DIR/bin/pi-t3"
assert_contains 'doctor reports the patch state' "$out" 'patch: patched OK'
assert_contains 'doctor reports a valid template' "$out" 'valid (no main)'
assert_contains 'doctor shows the live session binding' "$out" "$minted"

name_out="$(run_doctor name "$PROJECT")"
assert_contains 'doctor name resolves the bound profile' "$name_out" "$minted"

out="$( cd "$PROJECT" && env -i HOME="$SB/home" PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" \
  PI_CODING_AGENT_DIR="$AGENT_DIR" OPTCHAT_HOME="$OPTCHAT" \
  PI_CODING_AGENT_SESSION_DIR="$SESSIONS" PI_T3_TEMPLATE="$TEMPLATE" \
  T3_SETTINGS="$SB/missing-settings.json" \
  bash "$REPO_DIR/bin/pi-t3-doctor" 2>&1 )"; code=$?
assert_eq 'doctor exits 1 when T3 settings are missing' "$code" '1'

# ---------------------------------------------------------------- summary ---
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  printf 'failed:%b\n' "$FAILED_NAMES"
  exit 1
fi
