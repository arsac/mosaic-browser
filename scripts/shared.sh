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

    # chromium-linux-tarballs' linux tarball: Google does not publish a -lite
    # tarball for every release, and this one's content has matched Chromium's
    # git for every file the patches touch. The pin guards against the release
    # asset changing.
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
    python3 - third_party/blink/common/BUILD.gn "${shared}"/cuttle_* <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
missing = [f for f in sorted(pathlib.Path(a).name for a in sys.argv[2:]) if f'"{f}"' not in s]
if missing:
    i = s.find("sources = [")
    if i < 0:
        sys.exit(f"{p}: no sources = [ block found")
    nl = s.find("\n", i)
    p.write_text(s[:nl] + "".join(f'\n    "{f}",' for f in missing) + s[nl:])
PY
    cd "${_root}"
}

# The build inputs gclient hooks and CIPD would provide, fetched at the
# versions this tree's DEPS pins. From cuttle's build-linux.sh stage 5.
setup_build_inputs() {
    local cipd="${_depot_tools}/cipd"
    cd "${_src_dir}"

    # What gclient writes from DEPS' gclient_gn_args, with cuttle's values:
    # every checkout_* false (its --nohooks checkout has none of them) and the
    # rest as DEPS sets them. Generated rather than listed, so a key a new
    # Chromium adds is never missing. Replaced only on a content change, so a
    # resumed tree is not regenerated.
    python3 - DEPS > "${_build_dir}/gclient_args.gni" <<'PY'
import sys
g = {"Str": str}
g["Var"] = lambda k: g["vars"][k]
exec(open(sys.argv[1]).read(), g)
for name in g["gclient_gn_args"]:
    value = g["vars"][name]
    if name.startswith("checkout_") or isinstance(value, bool):
        value = "false" if name.startswith("checkout_") else str(value).lower()
    else:
        value = '"%s"' % value
    print(f"{name} = {value}")
print("non_git_source = false")
PY
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

    # gn, the Dawn Go toolchain and gperf come from here too, at the versions
    # DEPS pins. A recursedep's DEPS missing from the tree would be skipped
    # silently, so the tools the build cannot do without are checked by name.
    python3 "${_root}/scripts/fetch-cipd-deps.py" "${_src_dir}" "${cipd}"
    local tool
    for tool in buildtools/linux64/gn \
                third_party/dawn/tools/golang/linux-amd64/bin/go \
                third_party/gperf/cipd/bin/gperf; do
        [ -x "${tool}" ] || { echo "${tool} missing after fetching the DEPS packages" >&2; exit 1; }
    done
}

write_gn_args() {
    mkdir -p "${_out_dir}"
    # ungoogled's flags.gn goes in first: its patches assume those flags, and
    # building without them fails ~30k targets in. Keys our flags.gn sets again
    # are dropped from it so each has exactly one assignment.
    local ours
    ours=$(sed -nE 's/^([a-z0-9_]+) *=.*/\1/p' "${_root}/flags.gn" | paste -sd'|' -)
    grep -vE "^(${ours}) *=" "${_main_repo}/flags.gn" > "${_out_dir}/args.gn"
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
               for f in "${_root}"/patches/stealth/000-shared/*.cc; do
                   echo "third_party/blink/common/${f##*/}"
               done) \
             | grep -E '\.(cc|c|mm)$' | LC_ALL=C sort -u)
    ninja -C out/Default -k 0 "${targets[@]}"
}
