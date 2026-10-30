#!/usr/bin/env bash
# install.sh — install pi-t3 into a prefix (~/.local by default).
#
#   ./install.sh                 copy bin/* and the template into $PREFIX
#   ./install.sh --link          symlink instead of copy (repo stays the source)
#   ./install.sh --force         overwrite an existing profile-template.json
#   PREFIX=/usr/local ./install.sh
#
# License: MIT. See LICENSE.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
PREFIX="${PREFIX:-$HOME/.local}"
MODE="copy"
FORCE=0

usage() {
  cat <<'EOF'
Usage: ./install.sh [--link] [--force] [--help]

  --link    symlink ~/.local/bin/pi-t3* to this checkout instead of copying
  --force   overwrite an existing profile-template.json

Environment:
  PREFIX    install prefix (default: ~/.local)
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --link) MODE="link" ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 64 ;;
  esac
  shift
done

BIN_DIR="$PREFIX/bin"
SHARE_DIR="$PREFIX/share/pi-t3"
mkdir -p "$BIN_DIR" "$SHARE_DIR"

for script in pi-t3 pi-t3-doctor pi-t3-patch-optchat; do
  src="$REPO_DIR/bin/$script"
  dest="$BIN_DIR/$script"
  if [ "$MODE" = "link" ]; then
    rm -f "$dest"
    ln -s "$src" "$dest"
    printf 'linked  %s -> %s\n' "$dest" "$src"
  else
    rm -f "$dest"
    install -m 0755 "$src" "$dest"
    printf 'copied  %s\n' "$dest"
  fi
done

template_dest="$SHARE_DIR/profile-template.json"
template_state="pending"
if [ -f "$template_dest" ] && [ "$FORCE" -ne 1 ]; then
  printf 'kept    %s (exists; use --force to regenerate)\n' "$template_dest"
  template_state="kept"
else
  # Seed the template from the model this Pi already uses, so a fresh install
  # produces usable profiles without hand-editing JSON.
  settings="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/settings.json"
  if [ -f "$settings" ] && python3 - "$settings" "$template_dest" <<'PY'
import json
import os
import sys

settings_path, dest = sys.argv[1:3]
try:
    settings = json.load(open(settings_path, encoding="utf-8"))
except Exception:
    raise SystemExit(1)

provider = settings.get("defaultProvider")
model = settings.get("defaultModel")
level = settings.get("defaultThinkingLevel")
if not (isinstance(provider, str) and provider and isinstance(model, str) and model):
    raise SystemExit(1)
if level not in {"off", "minimal", "low", "medium", "high", "xhigh", "max"}:
    level = "high"

template = {
    "compactor": {"provider": provider, "model": model, "thinking": "medium"},
    "subagent": {"provider": provider, "model": model, "thinking": level},
}
os.makedirs(os.path.dirname(dest), exist_ok=True)
tmp = dest + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(template, handle, indent=2)
    handle.write("\n")
os.chmod(tmp, 0o644)
os.replace(tmp, dest)
PY
  then
    printf 'derived %s (from %s)\n' "$template_dest" "$settings"
    template_state="derived"
  else
    printf 'skipped profile-template.json: no default model found in %s\n' "$settings"
    printf '        new profiles will be seeded from Pi default model settings instead\n'
    printf '        example shape: %s\n' "$REPO_DIR/share/profile-template.example.json"
    template_state="absent"
  fi
fi

cat <<EOF

Installed. Next steps:

1. Make sure $BIN_DIR is on PATH (T3's service does not inherit your shell PATH,
   but pi-t3 finds node on its own; the wrapper path must be absolute).

2. Point T3 Code at the wrapper:
     Providers -> Pi -> Binary path: $BIN_DIR/pi-t3
     Providers -> Pi -> Launch arguments: (empty)

3. Patch pi-optchat for this machine (safe to re-run):
     $BIN_DIR/pi-t3-patch-optchat --check
     $BIN_DIR/pi-t3-patch-optchat

4. Verify:
     $BIN_DIR/pi-t3-doctor

Template: $template_dest ($template_state)
  Profile model defaults. Delete it to fall back to Pi's own default model, and
  see share/profile-template.example.json for the expected shape.
EOF
