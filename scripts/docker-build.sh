#!/bin/bash
# Run .github/scripts/build.sh inside the builder image with the repo mounted
# at /repo. Adapted from ungoogled-chromium-portablelinux (BSD-3-Clause).
set -euo pipefail

_base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_image="chromium-builder"

if [ -z "${_use_existing_image:-}" ]; then
    # shellcheck source=versions.env
    . "${_base_dir}/versions.env"
    docker buildx build --load -t "${_image}" --build-arg "CHROMIUM_VERSION=${CHROMIUM_VERSION}" \
        -f "${_base_dir}/docker/build.Dockerfile" "${_base_dir}/docker"
fi

_extra_env=()
[ -n "${_prepare_only:-}" ] && _extra_env+=(-e _prepare_only)
[ -n "${_gha_final:-}" ] && _extra_env+=(-e _gha_final)
[ -n "${_job_start:-}" ] && _extra_env+=(-e _job_start)

_mounts=(-v "${_base_dir}:/repo")
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    _extra_env+=(-e GITHUB_OUTPUT)
    _mounts+=(-v "${GITHUB_OUTPUT}:${GITHUB_OUTPUT}")
fi

# Match the host user so files written to the bind mount stay ours.
docker run --rm -i \
    -u "$(id -u):$(id -g)" \
    "${_mounts[@]}" \
    "${_extra_env[@]}" \
    "${_image}" bash /repo/.github/scripts/build.sh
