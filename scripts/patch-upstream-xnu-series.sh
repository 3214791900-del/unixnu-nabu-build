#!/bin/bash
# Patch the upstream XNU build script so the device patch series applies on a
# newer XNU than it was written against, and so a patch that is already in the
# tree is treated as applied instead of fatal. Runs inside the cloned tree.
set -euo pipefail
ROOT="${1:-unixnu}"
F="$ROOT/scripts/build-xnu-4k-baseline.sh"
python3 - "$F" <<'PY'
import pathlib, re, sys

p = pathlib.Path(sys.argv[1])
if not p.is_file():
    print(f'{p}: missing')
    sys.exit(1)
t = p.read_text()

LOOP = '''for PATCH in "$ROOT"/patches/xnu/*.patch "$ROOT"/kits/NativePrelink/patches/*.patch; do
  [ -f "$PATCH" ] || continue
  case "$PATCH" in
    *nabu-master-second-trust-cache.patch)
      grep -q second_static_trust_cache .cache/xnu-work/config/MASTER.arm64 && continue ;;
  esac
  if git -C .cache/xnu-work apply --reverse --check "$PATCH" >/dev/null 2>&1; then
    continue
  fi
  if git -C .cache/xnu-work apply --check "$PATCH" >/dev/null 2>&1; then
    git -C .cache/xnu-work apply "$PATCH"
  else
    echo "fuzzy apply: $PATCH"
    patch -d .cache/xnu-work -p1 --fuzz=3 --forward -i "$PATCH" >/dev/null 2>&1 || true
    if git -C .cache/xnu-work apply --reverse --check "$PATCH" >/dev/null 2>&1; then
      echo "fuzzy ok: $PATCH"
    else
      echo "patch failed: $PATCH" >&2
      exit 1
    fi
  fi
done
'''

pattern = re.compile(r'for PATCH in "\$ROOT"/patches/xnu/\*\.patch "\$ROOT"/kits/NativePrelink/patches/\*\.patch; do\n.*?\ndone\n', re.S)
m = pattern.search(t)
if m:
    t = t[:m.start()] + LOOP + t[m.end():]
    print('patch loop replaced')
else:
    print('patch loop not found (already patched?)')

p.write_text(t)
PY
