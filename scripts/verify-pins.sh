#!/bin/bash
# Verify the pins in versions.env resolve, cheaply: no Chromium source, no
# 1.2 GB download. Runs on every pull request so a half-applied bump fails here
# instead of after a 13h build starts.
#
#   - each tag pin still resolves to the commit recorded beside it, so a moved
#     tag fails here rather than building different source
#   - the tarball sha256 matches the .hashes file its own release publishes,
#     which is what scripts/update-tarball-pin.sh writes
#
# DEPOT_TOOLS_BRANCH is not checked: `main` moves daily by design and the build
# pins the commit, so being behind the tip is normal, not a fault. It cannot
# prove the patches apply or that the tree compiles either; that is prep.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=versions.env
. ./versions.env

fail=0
bad() { echo "::error::$*" >&2; fail=1; }

# The `^{}` dereference only shows up when the pattern has a wildcard: matching
# the bare refname lists the annotated tag object alone.
resolve_tag() { # url tag -> the commit the tag points at
    git ls-remote --tags "$1" "refs/tags/$2*" | awk -v plain="refs/tags/$2" -v deref="refs/tags/$2^{}" '
        $2 == deref { d = $1 } $2 == plain { p = $1 } END { print (d != "" ? d : p) }'
}

check_tag() { # name, url, tag, expected
    local actual
    actual=$(resolve_tag "$2" "$3")
    [ "${actual}" = "$4" ] \
        || bad "$1: tag $3 is ${actual:-missing} upstream, versions.env pins $4"
}

check_tag ungoogled-chromium https://github.com/ungoogled-software/ungoogled-chromium.git \
    "${UC_TAG}" "${UC_COMMIT}"
check_tag cuttle https://github.com/glim-sh/cuttle.git "${CUTTLE_TAG}" "${CUTTLE_COMMIT}"

url="https://github.com/chromium-linux-tarballs/chromium-tarballs/releases/download/${CHROMIUM_VERSION}/chromium-${CHROMIUM_VERSION}-linux.tar.xz.hashes"
if ! hashes=$(curl -fsSL "${url}"); then
    bad "no tarball hashes at ${url}: the release is not published yet, so the pin cannot be moved"
else
    sha=$(awk '$1 == "sha256" { print $2 }' <<< "${hashes}")
    case "${sha}" in
        "" | *[!0-9a-f]*) bad "no sha256 in ${url}" ;;
        *) [ "${sha}" = "${CHROMIUM_TARBALL_SHA256}" ] \
            || bad "tarball sha256 is ${sha}, versions.env pins ${CHROMIUM_TARBALL_SHA256}: run scripts/update-tarball-pin.sh" ;;
    esac
fi

exit "${fail}"
