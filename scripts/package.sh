#!/bin/bash
# Package the built binaries as mosaic-browser-<version>-linux-x64.tar.xz plus a
# .sha256 and version.json, into build/release. Adapted from
# ungoogled-chromium-portablelinux scripts/package.sh (BSD-3-Clause); the file
# selection is cuttle's (build-linux.sh stage 7): what the browser cannot start
# without is named, so its absence fails here, and the rest is taken by type,
# so a runtime file a new Chromium adds is not silently left out.
#
# version.json is the contract for consumers of the tarball: they read the
# Chromium version the persona flags must match from it rather than restating it.
#
# Usage: package.sh <version>
set -euo pipefail

_version="${1:?usage: package.sh <version>}"
_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_out_dir="${_root}/build/src/out/Default"
_release_dir="${_root}/build/release"
_name="mosaic-browser-${_version}-linux-x64"

# shellcheck source=versions.env
. "${_root}/versions.env"

rm -rf "${_release_dir:?}/${_name}"
mkdir -p "${_release_dir}/${_name}"
(
    cd "${_out_dir}"
    for f in chrome chromedriver chrome_crashpad_handler icudtl.dat resources.pak locales; do
        [ -e "${f}" ] || { echo "${f} is missing from ${_out_dir}" >&2; exit 1; }
    done
    # *.so.[0-9]* keeps versioned libraries (libvulkan.so.1), not ninja's .so.TOC.
    shopt -s nullglob
    files=(chrome chromedriver chrome_crashpad_handler icudtl.dat locales *.pak *.bin *.json *.so *.so.[0-9]*)
    [ -e chrome_sandbox ] && files+=(chrome_sandbox)
    cp -r "${files[@]}" "${_release_dir}/${_name}/"
)
# Binary redistribution of the BSD-3-Clause parts requires the notices.
cp "${_root}/LICENSE" "${_root}/THIRD-PARTY.md" "${_release_dir}/${_name}/"
cat > "${_release_dir}/version.json" <<JSON
{
  "version": "${_version}",
  "chromium_version": "${CHROMIUM_VERSION}",
  "uc_tag": "${UC_TAG}",
  "uc_commit": "${UC_COMMIT}",
  "cuttle_commit": "${CUTTLE_COMMIT}",
  "portablelinux_commit": "${PORTABLELINUX_COMMIT}",
  "source_commit": "$(git -C "${_root}" rev-parse HEAD)"
}
JSON
cp "${_release_dir}/version.json" "${_release_dir}/${_name}/"

cd "${_release_dir}"
tar -cf - "${_name}" | xz -T0 -6 > "${_name}.tar.xz"
sha256sum "${_name}.tar.xz" | tee "${_name}.tar.xz.sha256"
rm -rf "${_release_dir:?}/${_name}"
