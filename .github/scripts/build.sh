#!/bin/bash
# Runs inside the builder container. With _prepare_only=true it prepares the
# tree up to gn gen and compiles the files the stealth series touches;
# otherwise it runs ninja until just short of the 6h job limit and reports
# whether the next chained job must continue.
# Adapted from ungoogled-chromium-portablelinux (BSD-3-Clause).
#
# _prepare_only=true is also the whole of the pull-request gate: every pin
# resolves, every patch applies, gn accepts the tree and the patched sources
# compile, before any multi-hour build is spent on them.
set -euxo pipefail

# shellcheck source=scripts/shared.sh
. "/repo/scripts/shared.sh"

setup_paths

if [ "${_prepare_only:-}" = true ]; then
    fetch_tools
    fetch_sources
    apply_ungoogled_patches
    apply_stealth_patches
    setup_build_inputs
    write_gn_args
    gn_gen
    compile_patched_sources
else
    # The 6h job limit, less what saving the tree takes afterwards (compress
    # and upload ~5 GB, retries included) and the time the job has already
    # spent restoring it.
    _reserve=3600
    _elapsed=$(( $(date +%s) - ${_job_start:-$(date +%s)} ))
    _task_timeout=$(( 6 * 3600 - _reserve - _elapsed ))
    if [ "${_task_timeout}" -lt 600 ]; then
        echo "only ${_task_timeout}s left after restoring the tree" >&2
        exit 1
    fi
    cd "$_src_dir"

    set +e
    # -k 0: a compile error in one stealth patch must not stop the other
    # targets, so one 13h run surfaces every broken patch at once.
    timeout -k 5m -s INT "${_task_timeout}"s ninja -C out/Default -k 0 chrome chromedriver
    rc=$?
    set -e

    if [ "${_gha_final:-}" != "true" ] && [ "$rc" -eq 124 ]; then
        echo "Task timed out after ${_task_timeout}s; continuing in next run."
        echo "status=running" >> "$GITHUB_OUTPUT"
        exit 0
    elif [ "$rc" -eq 0 ] && [ -x "${_out_dir}/chrome" ] && [ -x "${_out_dir}/chromedriver" ]; then
        echo "status=completed" >> "$GITHUB_OUTPUT"
    fi

    exit "$rc"
fi
