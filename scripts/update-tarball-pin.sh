#!/bin/bash
# Point CHROMIUM_TARBALL_SHA256 at the source tarball for the Chromium version
# versions.env pins. Renovate runs it after moving UC_TAG. It fails while the
# tarball is not published yet, and Renovate tries again on its next run.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=versions.env
. ./versions.env

url="https://github.com/chromium-linux-tarballs/chromium-tarballs/releases/download/${CHROMIUM_VERSION}/chromium-${CHROMIUM_VERSION}-linux.tar.xz.hashes"
sha=$(curl -fsSL "${url}" | awk '$1 == "sha256" { print $2 }')
if ! [[ "${sha}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "no sha256 in ${url}" >&2
    exit 1
fi
sed "s/^CHROMIUM_TARBALL_SHA256=.*/CHROMIUM_TARBALL_SHA256=${sha}/" versions.env > versions.env.new
mv versions.env.new versions.env
