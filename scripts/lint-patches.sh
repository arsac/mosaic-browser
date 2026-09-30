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

if ! compgen -G '000-shared/cuttle_*.cc' >/dev/null || ! compgen -G '000-shared/cuttle_*.h' >/dev/null; then
    echo "000-shared has no cuttle_*.cc/.h files; the series cannot compile without them" >&2
    rc=1
fi

exit "${rc}"
