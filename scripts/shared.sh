#!/bin/bash
# Build functions for the CI stages. The tree is prepared the way cuttle's
# build-linux.sh prepares it (glim-sh/cuttle, MIT): ungoogled's patches and the
# stealth series only - no binary pruning, no domain substitution - with
# Chromium's own pinned tools, so the binary matches the one the series is
# validated on. The source comes from the release tarball instead of a gclient
# checkout, which fits the free-runner job chain adapted from
# ungoogled-chromium-portablelinux (BSD-3-Clause).
set -euo pipefail

setup_paths() {
    _root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    _build_dir="${_root}/build"
    _main_repo="${_build_dir}/ungoogled-chromium"
    _depot_tools="${_build_dir}/depot_tools"
    _dl_cache="${_build_dir}/download_cache"
    _src_dir="${_build_dir}/src"
    _out_dir="${_src_dir}/out/Default"

    # shellcheck source=versions.env
    . "${_root}/versions.env"

    mkdir -p "${_dl_cache}"
}

# Shallow fetch of one pinned commit: $1 url, $2 commit, $3 destination.
fetch_pinned() {
    if [ ! -d "$3/.git" ]; then
        git init -q "$3"
        git -C "$3" fetch -q --depth=1 "$1" "$2"
        git -C "$3" checkout -q FETCH_HEAD
    fi
    local head
    head="$(git -C "$3" rev-parse HEAD)"
    if [ "${head}" != "$2" ]; then
        echo "$3 is at ${head}, versions.env pins $2" >&2
        exit 1
    fi
}

fetch_tools() {
    fetch_pinned https://github.com/ungoogled-software/ungoogled-chromium.git "${UC_COMMIT}" "${_main_repo}"
    fetch_pinned https://chromium.googlesource.com/chromium/tools/depot_tools.git "${DEPOT_TOOLS_COMMIT}" "${_depot_tools}"
}

fetch_sources() {
    local stamp="${_src_dir}/.downloaded.stamp"
    if [ -f "${stamp}" ]; then
        if [ "$(cat "${stamp}")" != "${CHROMIUM_TARBALL_SHA256}" ]; then
            echo "the tree was unpacked from another tarball; it cannot be resumed" >&2
            exit 1
        fi
        echo "Sources already present, skipping download/unpack"
        return 0
    fi

    # chromium-linux-tarballs' linux tarball: Google published no -lite tarball
    # for 154, and its content matches Chromium's git for every file the
    # patches touch. The pin guards against the release asset changing.
    sed -i 's|https://commondatastorage.googleapis.com/chromium-browser-official|https://github.com/chromium-linux-tarballs/chromium-tarballs/releases/download/%(_chromium_version)s|g' "${_main_repo}/downloads.ini"
    sed -i 's|chromium-%(_chromium_version)s-lite.tar.xz|chromium-%(_chromium_version)s-linux.tar.xz|g' "${_main_repo}/downloads.ini"
    "${_main_repo}/utils/downloads.py" retrieve -i "${_main_repo}/downloads.ini" -c "${_dl_cache}"
    echo "${CHROMIUM_TARBALL_SHA256}  ${_dl_cache}/chromium-${CHROMIUM_VERSION}-linux.tar.xz" | sha256sum -c -
    "${_main_repo}/utils/downloads.py" unpack -i "${_main_repo}/downloads.ini" -c "${_dl_cache}" "${_src_dir}"

    echo "${CHROMIUM_TARBALL_SHA256}" > "${stamp}"
}

apply_ungoogled_patches() {
    local stamp="${_src_dir}/.ungoogled.stamp"
    if [ -f "${stamp}" ]; then
        return 0
    fi

    # Fuzz 3, as cuttle applies them: ungoogled's patches are authored for this
    # exact tag and a few genuinely need it. A partially patched tree would
    # still build, so any failure stops the build.
    local p failed=()
    while read -r p; do
        [ -n "${p}" ] || continue
        if ! (cd "${_src_dir}" && patch -p1 --batch --forward --no-backup-if-mismatch -F3 \
                < "${_main_repo}/patches/${p}"); then
            failed+=("${p}")
        fi
    done < <(grep -v '^#' "${_main_repo}/patches/series")
    if [ "${#failed[@]}" -gt 0 ]; then
        printf 'ungoogled patch failed: %s\n' "${failed[@]}" >&2
        exit 1
    fi

    touch "${stamp}"
}

# Applies the stealth series so that a tree prepared for an earlier version of
# the series (a resumed run) ends up exactly as a fresh prep would leave it,
# while touching only the files whose patches changed: every other file keeps
# its mtime, so ninja rebuilds only what the change affects.
#
# .stealth-applied/<name>.<hash>.patch is a copy of each patch as applied. A
# patch that changed or left the series is reversed from that copy, which
# restores every file it touched, then the current version is applied. A later
# patch sharing a file with one being redone is redone too. Ported from
# cuttle's build-linux.sh stage 4 (glim-sh/cuttle, MIT).
apply_stealth_patches() {
    "${_root}/scripts/lint-patches.sh"

    cd "${_src_dir}"
    # The ceiling stops git from finding this repository's .git above the
    # (non-git) source tree.
    export GIT_CEILING_DIRECTORIES="${_build_dir}"
    local applied=.stealth-applied
    mkdir -p "${applied}"
    shopt -s nullglob

    local -a series=("${_root}"/patches/stealth/0*.patch)
    local -A want=() dirty=()
    local p name names rec cur files f hit
    local -a recs redo=() todo=()
    for p in "${series[@]}"; do
        want[${p##*/}]=$(sha256sum "${p}" | cut -c1-16)
    done
    names=$( (for rec in "${applied}"/*.patch; do rec=${rec##*/}; echo "${rec%.*.patch}"; done
              for p in "${series[@]}"; do echo "${p##*/}"; done) | LC_ALL=C sort -u)
    for name in ${names}; do
        recs=("${applied}/${name}".*.patch)
        rec=${recs[0]:-}
        cur=""
        [ -n "${want[${name}]:-}" ] && cur="${applied}/${name}.${want[${name}]}.patch"
        files=$( ([ -z "${rec}" ] || git apply --numstat "${rec}" | cut -f3
                  [ -z "${cur}" ] || git apply --numstat "${_root}/patches/stealth/${name}" | cut -f3) | sort -u)
        hit=0
        [ "${rec}" != "${cur}" ] && hit=1
        for f in ${files}; do [ -n "${dirty[${f}]:-}" ] && hit=1; done
        [ "${hit}" = 1 ] || continue
        for f in ${files}; do dirty[${f}]=1; done
        [ -n "${rec}" ] && redo=("${rec}" "${redo[@]}")
        [ -n "${cur}" ] && todo+=("${_root}/patches/stealth/${name}")
    done

    for rec in "${redo[@]}"; do
        echo "reversing ${rec##*/}"
        if ! git apply -R "${rec}"; then
            echo "${rec##*/} no longer reverses: the tree was changed outside this script" >&2
            exit 1
        fi
        rm "${rec}"
    done
    for p in "${todo[@]}"; do
        # git apply, not patch: no fuzz, so a hunk cannot land in the wrong
        # function, and atomic per patch.
        echo "applying ${p##*/}"
        git apply "${p}"
        cp "${p}" "${applied}/${p##*/}.${want[${p##*/}]}.patch"
    done
    shopt -u nullglob

    # 000-shared holds new files, not diffs. The patches include the headers
    # from either directory; the .cc files compile once, into blink_common.
    # Copied only on a content change: the header has ~25 includers.
    local shared="${_root}/patches/stealth/000-shared" dest
    for f in "${shared}"/cuttle_*.h "${shared}"/cuttle_*.cc; do
        for dest in third_party/blink/common chrome/common; do
            case "${dest}/${f##*/}" in chrome/common/*.cc) continue ;; esac
            cmp -s "${f}" "${dest}/${f##*/}" || cp "${f}" "${dest}/"
        done
    done
    grep -q '"cuttle_seed.cc"' third_party/blink/common/BUILD.gn || python3 - third_party/blink/common/BUILD.gn <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
i = s.find("sources = [")
if i < 0:
    sys.exit(f"{p}: no sources = [ block found")
nl = s.find("\n", i)
files = ["cuttle_fingerprint_switches.cc", "cuttle_fingerprint_switches.h",
         "cuttle_seed.cc", "cuttle_seed.h"]
p.write_text(s[:nl] + "".join(f'\n    "{f}",' for f in files) + s[nl:])
PY
    cd "${_root}"
}

# The build inputs gclient hooks and CIPD would provide, fetched at the
# versions this tree's DEPS pins. From cuttle's build-linux.sh stage 5.
setup_build_inputs() {
    local cipd="${_depot_tools}/cipd"
    cd "${_src_dir}"

    local gn_rev
    gn_rev=$(grep "'gn_version'" DEPS | sed -E "s/.*git_revision:([a-f0-9]+).*/\1/" | head -1)
    "${cipd}" install "gn/gn/linux-amd64" "git_revision:${gn_rev}" -root buildtools/linux64

    local go_ver
    go_ver=$(grep -E "'dawn_go_version'" third_party/dawn/DEPS | sed -E "s/.*'(version:[^']+)'.*/\1/" | head -1)
    [ -n "${go_ver}" ] || { echo "no dawn_go_version in third_party/dawn/DEPS" >&2; exit 1; }
    "${cipd}" install "infra/3pp/tools/go/linux-amd64" "${go_ver}" -root third_party/dawn/tools/golang/linux-amd64

    "${cipd}" install "infra/3pp/tools/gperf/linux-amd64" "version:3@3.2" -root third_party/gperf/cipd

    # Written by gclient runhooks, which the tarball's export does not keep.
    # Replaced only on a content change, so a resumed tree is not regenerated.
    cat > "${_build_dir}/gclient_args.gni" <<'GNI'
checkout_android = false
checkout_android_prebuilts_build_tools = false
checkout_android_native_support = false
checkout_chromium_autofill_test_dependencies = false
checkout_chromium_internal_resources = false
checkout_clusterfuzz_data = false
checkout_chromevox_dependencies = false
checkout_clang_coverage_tools = false
checkout_clang_tidy = false
checkout_clangd = false
checkout_copybara = false
checkout_cros_internal = false
checkout_fuchsia = false
checkout_fuchsia_for_arm64_host = false
checkout_fuchsia_internal = false
checkout_glic = false
checkout_glic_e2e_tests = false
checkout_glic_internal = false
checkout_ios = false
checkout_ios_webkit = false
checkout_libaom_testdata = false
checkout_libvpx_testdata = false
checkout_lottie_proprietary_tests = false
checkout_mac_sdk = false
checkout_mutter = false
checkout_nacl = false
checkout_openxr = false
checkout_oculus_sdk = false
checkout_optimization_profiles = false
checkout_pgo_profiles = false
checkout_remoteexec = false
checkout_rts_model = false
checkout_src_internal = false
checkout_telemetry_dependencies = false
checkout_test_data = false
checkout_traffic_annotation_tools = false
checkout_webp_dirs = false
build_with_chromium = true
cros_boards = ""
cros_boards_with_qemu_images = ""
generate_location_tags = true
non_git_source = false
GNI
    cmp -s "${_build_dir}/gclient_args.gni" build/config/gclient_args.gni \
        || cp "${_build_dir}/gclient_args.gni" build/config/gclient_args.gni

    # Parity with cuttle's build, whose --nohooks checkout lacks the version
    # stamps and so gets placeholders (build-linux.sh stage 5). The tarball
    # ships the real ones, which are the better end state (deterministic, and
    # what official Chrome embeds), but the first builds match cuttle in
    # everything that can be matched. Written once, so a resumed tree is not
    # re-stamped into rebuilding.
    if ! grep -q -- '-stub$' build/util/LASTCHANGE 2>/dev/null; then
        echo "LASTCHANGE=$(date -u +%Y-%m-%dT%H:%M:%S)-stub" > build/util/LASTCHANGE
        date +%s > build/util/LASTCHANGE.committime
    fi
    local stamp header line
    for stamp in gpu/config/gpu_lists_version.h:GPU_LISTS_VERSION \
                 skia/ext/skia_commit_hash.h:SKIA_COMMIT_HASH \
                 skia/skia_commit_hash.h:SKIA_COMMIT_HASH; do
        header=${stamp%%:*}
        line="#define ${stamp##*:} \"0000000000000000000000000000000000000000\""
        if [ "$(cat "${header}" 2>/dev/null)" != "${line}" ]; then
            mkdir -p "$(dirname "${header}")"
            echo "${line}" > "${header}"
        fi
    done

    # Both scripts skip the download when their stamp matches.
    python3 tools/rust/update_rust.py
    python3 tools/clang/scripts/update.py
    [ -x third_party/node/linux/node-linux-x64/bin/node ] || bash third_party/node/update_node_binaries

    python3 "${_root}/scripts/fetch-cipd-deps.py" "${_src_dir}" "${cipd}"
}

write_gn_args() {
    mkdir -p "${_out_dir}"
    # ungoogled's flags.gn goes in first: its patches assume those flags, and
    # building without them fails ~30k targets in. Keys flags.gn sets again
    # are dropped so each has exactly one assignment.
    grep -vE '^(chrome_pgo_phase|enable_remoting|safe_browsing_mode|treat_warnings_as_errors|enable_widevine)=' \
        "${_main_repo}/flags.gn" > "${_out_dir}/args.gn"
    cat "${_root}/flags.gn" >> "${_out_dir}/args.gn"
    cat "${_out_dir}/args.gn"
}

gn_gen() {
    cd "${_src_dir}"
    # A different ninja rewrites .ninja_log and rebuilds everything, which
    # would silently turn a resumed run into a full one.
    local version_file=out/Default/.ninja-version
    if [ -f "${version_file}" ] && [ "$(cat "${version_file}")" != "$(ninja --version)" ]; then
        echo "the tree was built with ninja $(cat "${version_file}"), this builder has $(ninja --version)" >&2
        exit 1
    fi
    buildtools/linux64/gn gen out/Default
    ninja --version > "${version_file}"
    # ninja reports only the first missing source input, after minutes of
    # setup; list them all up front.
    ninja -C out/Default -t inputs chrome chromedriver | python3 -c '
import os, sys
gone = [f for f in sys.stdin.read().split() if f.startswith("../../") and not os.path.exists(os.path.join("out/Default", f))]
for f in gone[:40]:
    print("missing input:", f[6:], file=sys.stderr)
sys.exit(1 if gone else 0)'
}

# Compiles every translation unit the stealth series touches, so a patch that
# applies but no longer compiles fails here instead of hours into the build.
# The objects stay in out/ and the full build reuses them.
compile_patched_sources() {
    cd "${_src_dir}"
    local -a targets=()
    local f
    while read -r f; do
        if ninja -C out/Default -t query "../../${f}" >/dev/null 2>&1; then
            targets+=("../../${f}^")
        else
            echo "not built by any target: ${f}"
        fi
    done < <( (grep -h '^+++ b/' "${_root}"/patches/stealth/0*.patch | sed 's|^+++ b/||'
               printf '%s\n' third_party/blink/common/cuttle_seed.cc \
                   third_party/blink/common/cuttle_fingerprint_switches.cc) \
             | grep -E '\.(cc|c|mm)$' | LC_ALL=C sort -u)
    ninja -C out/Default -k 0 "${targets[@]}"
}
