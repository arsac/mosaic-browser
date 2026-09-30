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

# Every cuttle_* header the series includes must come from 000-shared or be
# created by a patch; otherwise the failure only shows at compile time.
created=$(grep -h '^+++ b/' 0*.patch | sed 's|.*/||')
while read -r h; do
    if [ ! -f "000-shared/${h}" ] && ! grep -qx "${h}" <<< "${created}"; then
        echo "${h} is included by the series but neither in 000-shared nor created by a patch" >&2
        rc=1
    fi
done < <(grep -hoE '^\+#include "[^"]*cuttle_[a-z0-9_]+\.h"' 0*.patch | grep -oE 'cuttle_[a-z0-9_]+\.h' | sort -u)

exit "${rc}"
