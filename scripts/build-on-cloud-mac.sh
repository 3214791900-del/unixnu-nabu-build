#!/bin/bash
# Build the NABU (Xiaomi Pad 5) xnu-8796 kernel on any macOS box with Xcode 15.
#
# This mirrors .github/workflows/build-kernel-8796.yml so the same kernel can be
# produced on a rented Mac when GitHub Actions is queued or degraded.
#
# Requirements on the box:
#   * macOS 13.x or 14.x with Xcode 15.x installed in /Applications
#   * Homebrew, git, curl
#
# Usage:
#   bash build-on-cloud-mac.sh            # build and print the kernel path
#   ARTIFACT_DIR=~/out bash build-on-cloud-mac.sh
set -euo pipefail

REPO_OWNER="3214791900-del"
REPO_NAME="unixnu-nabu-build"
BRANCH="${BRANCH:-nabu-gpu-port}"
DXB_REPO="https://github.com/blacktop/darwin-xnu-build"
DXB_SHA="663906528d1cd5ea8fde7de6f16de73db9511549"
KERNEL_CONFIG="${KERNEL_CONFIG:-DEVELOPMENT}"
MACHINE_CONFIG_DEFAULT="NABU"
WORKDIR="${WORKDIR:-$HOME/nabu-build}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$HOME/nabu-artifacts}"

say() { printf '\n== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

say "checking the toolchain"
command -v git >/dev/null || die "git missing"
command -v curl >/dev/null || die "curl missing"
command -v brew >/dev/null || die "Homebrew missing - install it from https://brew.sh"
XC=$(ls -d /Applications/Xcode_15*.app 2>/dev/null | sort -V | tail -1 || true)
if [ -z "$XC" ]; then
    XC=$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -1 || true)
fi
[ -n "$XC" ] || die "no Xcode found under /Applications"
sudo xcode-select -s "$XC/Contents/Developer"
export DEVELOPER_DIR="$XC/Contents/Developer"
echo "using $XC"
xcodebuild -version || die "xcodebuild unusable"
xcrun --find iig >/dev/null || die "iig not found - Xcode 16+ dropped the 8796 support this kernel needs"

say "installing helper tools"
brew install jq gum bash cmake ninja >/dev/null 2>&1 || brew install jq cmake ninja >/dev/null 2>&1 || true

say "fetching the build harness at $DXB_SHA"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
git init -q dxb
git -C dxb fetch -q --depth 1 "$DXB_REPO" "$DXB_SHA"
git -C dxb checkout -q FETCH_HEAD
echo "harness at $(git -C dxb rev-parse HEAD)"

say "downloading our patches from GitHub ($REPO_OWNER/$REPO_NAME@$BRANCH)"
mkdir -p dxb/patches
curl -fsSL "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/git/trees/$BRANCH?recursive=1" \
    | grep -o '"path": *"xnu-8796/patches/[^"]*"' \
    | sed 's/.*"xnu-8796\/patches\///; s/"$//' > patch-list.txt
echo "$(wc -l < patch-list.txt | tr -d ' ') patch file(s) listed"
while IFS= read -r name; do
    [ -n "$name" ] || continue
    curl -fsSL "https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$BRANCH/xnu-8796/patches/$name" \
        -o "dxb/patches/$name"
done < patch-list.txt
ls dxb/patches | wc -l

say "normalising line endings (the patch set came from a Windows checkout)"
for f in dxb/patches/*.patch dxb/patches/*.sh; do
    [ -e "$f" ] || continue
    perl -pi -e 's/\r$//' "$f"
done
chmod +x dxb/patches/*.sh 2>/dev/null || true

say "letting the harness build plain arm64 as well (libfirehose_kernel is arm64e-only)"
if grep -q 'ARCHS="x86_64 arm64e"' dxb/build.sh; then
    sed -i '' 's/ARCHS="x86_64 arm64e"/ARCHS="x86_64 arm64e arm64"/; s/VALID_ARCHS="x86_64 arm64e"/VALID_ARCHS="x86_64 arm64e arm64"/' dxb/build.sh
fi
grep -c 'ARCHS=' dxb/build.sh || true

say "building (this is the long part, expect 8-20 minutes)"
cd "$WORKDIR/dxb"
export MACHINE_CONFIG="$MACHINE_CONFIG_DEFAULT"
export KERNEL_CONFIG
set +e
bash -x build.sh 2>&1 | tee build.log
rc=${PIPESTATUS[0]}
set -e
echo "build.sh exit: $rc"
if [ "$rc" -ne 0 ]; then
    say "first compiler diagnostics"
    grep -E 'error:' build.log | grep -v 'patch failed' | grep -v 'already exists' | head -20 || true
    exit "$rc"
fi

say "collecting the kernel"
mkdir -p "$ARTIFACT_DIR"
find "$WORKDIR/dxb" -name 'kernel.development.nabu' -o -name 'kernel.*.nabu' 2>/dev/null | while read -r k; do
    cp "$k" "$ARTIFACT_DIR/"
    echo "kernel: $k"
done
ls -l "$ARTIFACT_DIR"
( cd "$ARTIFACT_DIR" && shasum -a 256 kernel.* > SHA256SUMS && cat SHA256SUMS )

say "done"
cat <<EOF

Download it to the Windows box with:

  scp <user>@<host>:$ARTIFACT_DIR/kernel.development.nabu E:\\\\ai\\\\aii\\\\nabu-port\\\\shim-combo\\\\kernel-cloud\\\\

Then package and flash:

  python scripts/make-bootimg.py kernel.development.nabu --adt shim-combo/nabu.adt \\
      -o shim-combo/cloud.img --cmdline "rd=ufsroot0 ufsrw=1 rootrw=1 launchd_unsecure_cache=1 unentitled_ios_sim_launch=1 debug=0xc cpus=4 keepsyms=1 -enable_kprintf_spam nabulog_dump=0"

  fastboot flash boot_b shim-combo/cloud.img && fastboot reboot
EOF
