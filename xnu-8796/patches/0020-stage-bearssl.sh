#!/bin/bash
# Pinned, portable constant-time AES for the NABU legacy CBC/ECB API.
set -euo pipefail
[[ "${MACHINE_CONFIG:-}" == NABU ]] || exit 0
[[ -f libkern/crypto/corecrypto_aes.c ]] || exit 1
if [[ -d libkern/crypto/nabu_bearssl ]]; then
    echo "BearSSL source already staged; skipping"
    exit 0
fi
# bearssl.org's git server answers 502 or times out for CI runners often
# enough that the build needs a second source.  The Debian mirror carries the
# same upstream tree; both are pinned.
bearssl_org_sha=7bea48e5e850ab4cafbe68d3765cdaba13a86d6f
bearssl_deb_sha=001b4b1d91f050ab05aaead0951078e64fe80915
bearssl_tmp=$(mktemp -d)
trap 'rm -rf "$bearssl_tmp"' EXIT
git init -q "$bearssl_tmp"
bearssl_ok=0
for bearssl_pair in \
    "https://www.bearssl.org/git/BearSSL $bearssl_org_sha" \
    "https://salsa.debian.org/debian/bearssl.git $bearssl_deb_sha"
do
    set -- $bearssl_pair
    bearssl_url=$1
    bearssl_sha=$2
    if git -C "$bearssl_tmp" fetch -q --depth 1 "$bearssl_url" "$bearssl_sha" 2>/dev/null; then
        git -C "$bearssl_tmp" checkout -q FETCH_HEAD
        if [[ "$(git -C "$bearssl_tmp" rev-parse HEAD)" == "$bearssl_sha" ]]; then
            bearssl_ok=1
            echo "BearSSL fetched from $bearssl_url"
            break
        fi
    fi
done
[[ "$bearssl_ok" == 1 ]] || { echo "could not fetch BearSSL from any source" >&2; exit 1; }
python3 - "$bearssl_tmp" <<'PY'
from pathlib import Path
import shutil
import sys

source = Path(sys.argv[1])
target = Path('libkern/crypto/nabu_bearssl')
if target.exists():
    raise SystemExit(f'refusing to overwrite existing AES source: {target}')
shutil.copytree(source / 'inc', target / 'inc')
(target / 'src/symcipher').mkdir(parents=True)
for file in ('inner.h', 'config.h'):
    shutil.copy2(source / 'src' / file, target / 'src' / file)
# XNU exports machine/limits.h instead of the userspace limits.h.
header = target / 'src/inner.h'
text = header.read_text()
assert text.count('#include <limits.h>') == 1
header.write_text(text.replace('#include <limits.h>',
    '#if defined(KERNEL)\n#include <machine/limits.h>\n'
    '#else\n#include <limits.h>\n#endif'))
for name in ('aes_ct', 'aes_ct_enc', 'aes_ct_dec', 'aes_ct_cbcenc', 'aes_ct_cbcdec'):
    shutil.copy2(source / 'src/symcipher' / (name + '.c'),
                 target / 'src/symcipher' / (name + '.c'))
# MD5, SHA-1 and SHA-384/512 for the legacy hash APIs, with their codecs.
for name in ('hash/md5.c', 'codec/dec32le.c', 'codec/enc32le.c',
             'hash/sha1.c', 'codec/dec32be.c', 'codec/enc32be.c',
             'hash/sha2big.c', 'codec/dec64be.c', 'codec/enc64be.c'):
    (target / 'src' / name).parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source / 'src' / name, target / 'src' / name)
shutil.copy2(source / 'LICENSE.txt', target / 'LICENSE.txt')
PY
echo "Staged BearSSL portable AES, MD5, SHA-1 and SHA-384/512 ($bearssl_sha) for NABU"
