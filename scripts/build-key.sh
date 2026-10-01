#!/bin/bash
# Print the build key of a commit: a hash of everything that decides what the
# binary is, and nothing else. Two commits with the same key build the same
# browser, so a build for a key that was already built is reused instead of
# run again, and a release is cut once per key.
#
# In: the ungoogled-chromium and source tarball pins, flags.gn, the patches,
# and the scripts and image that prepare and compile the tree. Out: packaging
# (it does not change the binary), CI orchestration, tests, docs, and pins that
# only supply build tooling (depot_tools), so none of those costs a 13h build.
#
# Usage: build-key.sh [commit]   (default HEAD)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
commit="${1:-HEAD}"

{
    git show "${commit}:versions.env" | grep -E '^(UC_TAG|UC_COMMIT|CHROMIUM_TARBALL_SHA256)='
    git ls-tree -r "${commit}" -- flags.gn patches docker \
        scripts/shared.sh scripts/deps.py .github/scripts/build.sh
} | sha256sum | cut -c1-64
