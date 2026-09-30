#!/bin/bash
# Make patches/stealth cuttle's packages/browser/patches at CUTTLE_COMMIT, so
# the pull request that moves CUTTLE_TAG shows the whole patch diff for review.
# When that cuttle release was built on a newer ungoogled-chromium tag than
# ours (a Chromium major), move UC_TAG, UC_COMMIT and the tarball pin with it:
# the series is only rebased for the version it names.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=versions.env
. ./versions.env

tmp=$(mktemp -d "${TMPDIR:-/tmp}/cuttle.XXXXXX")
trap 'rm -rf "${tmp}"' EXIT
git init -q "${tmp}"
git -C "${tmp}" fetch -q --depth=1 https://github.com/glim-sh/cuttle.git "${CUTTLE_COMMIT}"
git -C "${tmp}" checkout -q FETCH_HEAD -- packages/browser/patches packages/browser/versions.env

rm -rf patches/stealth
cp -R "${tmp}/packages/browser/patches" patches/stealth
# Cuttle's notes on the shared files; the build does not read them.
rm -f patches/stealth/000-shared/README.md

uc_tag=$(sed -nE 's/^UC_TAG=([^ #]+).*/\1/p' "${tmp}/packages/browser/versions.env")
if [ "$(printf '%s\n%s\n' "${UC_TAG}" "${uc_tag}" | sort -V | tail -1)" != "${UC_TAG}" ]; then
    # The peeled ^{} ref is the commit an annotated tag points at; a
    # lightweight tag has only the plain ref.
    uc_commit=$(git ls-remote https://github.com/ungoogled-software/ungoogled-chromium.git \
                    "refs/tags/${uc_tag}" "refs/tags/${uc_tag}^{}" | sort -k2 | tail -1 | cut -f1)
    if ! [[ "${uc_commit}" =~ ^[0-9a-f]{40}$ ]]; then
        echo "ungoogled-chromium has no tag ${uc_tag}" >&2
        exit 1
    fi
    sed -e "s/^UC_TAG=.*/UC_TAG=${uc_tag}/" -e "s/^UC_COMMIT=.*/UC_COMMIT=${uc_commit}/" \
        versions.env > versions.env.new
    mv versions.env.new versions.env
    scripts/update-tarball-pin.sh
fi
