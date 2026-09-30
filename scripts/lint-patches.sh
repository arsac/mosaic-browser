#!/bin/bash
# Static checks on the stealth series that need no Chromium source.
#
# A zero-context insertion (`@@ -N,0 +M,K @@`, N > 0) carries no context at
# all: git apply moves it to the end of the file and still reports success.
# Only a compile would catch it, hours later. `@@ -0,0` (a new file) is fine.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../patches/stealth"

rc=0
if grep -nE '^@@ -[1-9][0-9]*,0 ' 0*.patch; then
    echo "zero-context insertion(s) above; regenerate those hunks with context" >&2
    rc=1
fi

for f in cuttle_fingerprint_switches.cc cuttle_fingerprint_switches.h cuttle_seed.cc cuttle_seed.h; do
    if [ ! -f "000-shared/${f}" ]; then
        echo "000-shared/${f} is missing" >&2
        rc=1
    fi
done

exit "${rc}"
