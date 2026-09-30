#!/bin/bash
# Package the built binaries as mosaic-browser-<version>-linux-x64.tar.xz plus a
# .sha256 and version.json, into build/release. File list from
# ungoogled-chromium-portablelinux scripts/package.sh (BSD-3-Clause), without
# its desktop-integration files.
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

_files="chrome
chrome_100_percent.pak
chrome_200_percent.pak
chrome_crashpad_handler
chromedriver
icudtl.dat
libEGL.so
libGLESv2.so
libqt5_shim.so
libqt6_shim.so
libvk_swiftshader.so
libvulkan.so.1
locales
resources.pak
v8_context_snapshot.bin
vk_swiftshader_icd.json"

rm -rf "${_release_dir:?}/${_name}"
mkdir -p "${_release_dir}/${_name}"
for f in ${_files}; do
    cp -r "${_out_dir}/${f}" "${_release_dir}/${_name}/"
done
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
