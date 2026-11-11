#!/usr/bin/env python3
"""Rewrite the device trust-cache patch against the pinned XNU context.

Upstream xnu-10063.141.1 gained option words on the VM_KASAN line, so the device
hunk no longer applies with its recorded context. The change itself (adding
second_static_trust_cache to SECURITY_BASE) is unchanged; only the hunk context
is narrowed to lines that still match.
"""
import pathlib
import sys

CONTENT = (
    '--- a/config/MASTER.arm64\n'
    '+++ b/config/MASTER.arm64\n'
    '@@ -74,3 +74,3 @@\n'
    ' #  VM_KASAN =       [ VM_BASE dynamic_codesigning kernel_tagging kernel_tbi config_kasan config_ubsan config_kcov config_ksancov ]\n'
    '-#  SECURITY_BASE =    [ config_macf kernel_integrity config_secure_bsd_root ]\n'
    '+#  SECURITY_BASE =    [ config_macf kernel_integrity config_secure_bsd_root second_static_trust_cache ]\n'
    ' #  SECURITY_RELEASE = [ SECURITY_BASE ]\n'
)

for target in sys.argv[1:]:
    p = pathlib.Path(target)
    if not p.is_file():
        print(f'{target}: missing')
        continue
    p.write_text(CONTENT)
    print(f'{target}: rewritten (narrow context)')
