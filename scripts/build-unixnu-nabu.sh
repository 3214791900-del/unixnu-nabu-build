#!/bin/bash
# Build the UniXNU nabu kernel on a Codemagic macOS runner.
#
# This mirrors zzweiqing's GitHub Actions workflow (hackios-mac-batch,
# .github/workflows/unixnu-source.yml) but pulls the device repository and its
# source-ci helpers straight from GitHub instead of vendoring them.
#
# Apple's IPSW is never stored: the runner downloads it from Apple's CDN, keeps
# the four members the kernel build needs and drops the rest.
set -euo pipefail

UNIXNU_REF="${UNIXNU_REF:-245aca1a9ec5b730b1cad80fade295800d2981f1}"
PROFILE="${PROFILE:-nabu_ufs_readonly_defconfig}"
IPSW_URL="${IPSW_URL:-https://updates.cdn-apple.com/2024FallFCS/fullrestores/062-78914/A081E8C4-D00A-4FC5-A650-A42EA1726236/iPad_10.2_17.7_21H16_Restore.ipsw}"
WORK="${CM_BUILD_DIR:-$PWD}"
cd "$WORK"

echo "=== profile: $PROFILE"
echo "=== unixnu ref: $UNIXNU_REF"

echo "=== 1. device repository"
rm -rf nabu-device
git clone --depth 1 https://github.com/zzweiqing/UniXNU-nabu.git nabu-device

echo "=== 1b. retarget the device trust-cache patch"
# Upstream XNU gained a longer VM_KASAN context line; rewrite the hunk so it
# applies cleanly instead of relying on patch fuzz.
python3 scripts/fix-nabu-trustcache-patch.py nabu-device/patches/xnu/nabu-master-second-trust-cache.patch || true
echo "=== 2. source-ci helpers"
# prepare_source.py and the qualification scripts come from the batch repository,
# prepare_ipsw_input.py and the board patches from the device repository; the
# device copy wins where both exist.
rm -rf batch source-ci
git clone --depth 1 https://github.com/zzweiqing/hackios-mac-batch.git batch
cp -R batch/source-ci ./source-ci
cp -R nabu-device/source-ci/. ./source-ci/

echo "=== 2b. reset board.toml to the bootstrap base"
# The published board.toml describes the proven GPU profile. prepare_source.py
# rewrites it from the unmodified bootstrap state, so restore that first.
cat > reset_board.py <<'PY'
import pathlib, re
p = pathlib.Path('nabu-device/board.toml')
t = p.read_text()
t = re.sub(r'defconfig = "[^"]+"', 'defconfig = "nabu_bootstrap_defconfig"', t, count=1)
replacement = ('archives = [\n'
               '  "build-corecrypto-14.py",\n'
               '  "build-corecrypto-14.py --namespace",\n'
               '  "build-nabu-platform.py ArmDTPlatform",\n'
               '  "build-nabu-platform.py ArmCpu",\n'
               '  "build-libpthread-kernel.py",\n'
               ']')
t = re.sub(r'archives = \[[^\]]*\]', replacement, t, count=1, flags=re.S)
# prelink closure: bootstrap only prelinks APFS and has no security initializer
t = re.sub(r'^early_security_init = .*\n', '', t, flags=re.M)
t = re.sub(r'roots = \[[^\]]*\]',
           'roots = [\n  "com.apple.filesystems.apfs",\n]', t, count=1, flags=re.S)
p.write_text(t)
print('board.toml reset to bootstrap')
PY
python3 reset_board.py
echo "=== 3. Apple IPSW -> small input"
if [ ! -f ipsw-small.zip ]; then
  if [ ! -s ipsw.ipsw ]; then
    echo "downloading IPSW"
    curl -L --retry 20 --retry-delay 5 -o ipsw.ipsw "$IPSW_URL"
  fi
  python3 source-ci/prepare_ipsw_input.py --ipsw ipsw.ipsw --output ipsw-small.zip
  rm -f ipsw.ipsw
fi
export UNIXNU_IPSW="$WORK/ipsw-small.zip"
echo "UNIXNU_IPSW=$UNIXNU_IPSW"

echo "=== 4. UniXNU core"
rm -rf unixnu
git clone --quiet --no-checkout https://github.com/UniXNU/UniXNU.git unixnu
git -C unixnu fetch --quiet origin "$UNIXNU_REF"
git -C unixnu checkout --quiet --detach "$UNIXNU_REF"

echo "=== 4b. teach this revision the 'soc' feed kind"
# The device feeds declare a "soc" source kind; this revision predates it.
python3 - <<'PY'
import pathlib

# 1) the feed parser's accepted kinds
p = pathlib.Path('unixnu/scripts/unixnu/config.py')
t = p.read_text()
old = "'refer': 'refer'}"
new = "'refer': 'refer', 'soc': 'socs'}"
if old in t and "'soc'" not in t:
    p.write_text(t.replace(old, new, 1))
    print('config.py: soc kind added')
else:
    print('config.py: already patched or anchor missing')

# 2) the tree assembler's kind -> directory table
for name in ('unixnu/scripts/unixnu/tree.py',):
    p = pathlib.Path(name)
    t = p.read_text()
    old = "{'driver': 'drivers', 'kit': 'kits', 'patch': 'patches', 'refer': 'refer'}"
    new = "{'driver': 'drivers', 'kit': 'kits', 'patch': 'patches', 'refer': 'refer', 'soc': 'socs'}"
    if old in t:
        p.write_text(t.replace(old, new, 1))
        print(name + ': soc kind added')
    else:
        print(name + ': anchor missing, left as is')
PY

echo "=== 4c. relax the upstream XNU patch loop"
# The device series predates a context change in config/MASTER.arm64, and a
# patch that is already in the tree must not be fatal.
bash scripts/patch-upstream-xnu-series.sh unixnu || true
echo "=== 5. assemble the source tree"
python3 source-ci/prepare_source.py \
  --upstream unixnu \
  --device nabu-device \
  --profile "$PROFILE" \
  --report "$WORK/source-prepare.json" 2>&1 | tail -40

echo "=== 6. host tools"
export HOMEBREW_NO_AUTO_UPDATE=1
for tool in llvm lld mtools dtc unifdef ninja; do
  brew list "$tool" >/dev/null 2>&1 || brew install "$tool"
done

echo "=== 6b. seed the DriverKit header cache"
# prepare-xnu-source.py asks api.github.com for two directory listings; anonymous
# calls from hosted runners hit HTTP 403. The listings are committed under
# ci-cache and copied into the tree cache so the script skips the API calls.
if [ -d "$WORK/ci-cache" ]; then
  mkdir -p unixnu/out/nabu/tree/.cache/sources
  cp -f "$WORK"/ci-cache/*.json unixnu/out/nabu/tree/.cache/sources/ 2>/dev/null || true
  ls -la unixnu/out/nabu/tree/.cache/sources || true
fi

echo "=== 7. build kernel"
export UNIXNU_DEVICE="$WORK/nabu-device"
echo "UNIXNU_DEVICE=$UNIXNU_DEVICE"
cd unixnu
./unixnu defconfig "$PROFILE" 2>&1 | tail -20
if ! ./unixnu build kernel 2>&1 | tail -40; then
  echo "=== kernel build failed; real errors follow ==="
  for log in out/nabu/logs/kernel-bootstrap.log out/nabu/logs/kernel.log; do
    if [ -f "$log" ]; then
      echo "--- $log (errors) ---"
      grep -nE "error:|Error [0-9]|\*\*\*|undefined|No such file" "$log" | tail -40 || true
      echo "--- $log (tail) ---"
      tail -30 "$log"
    fi
  done
  exit 1
fi

echo "=== 8. results"
find . -name "kernel.macho*" -o -name "*.adt" -o -name "*.trustcache" 2>/dev/null | head -40
ls -la out/nabu 2>/dev/null || true
