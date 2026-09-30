#!/usr/bin/env python3
"""Install the CIPD and GCS build inputs Chromium's DEPS gates on non_git_source.

Each release adds build inputs there (the hermetic cpython3 gn runs on, the
typescript compiler and esbuild devtools needs, clang-format, ...), and neither
the source tarball nor a --nohooks checkout provides all of them. This evaluates
DEPS and every recursedep's DEPS, and installs each missing linux package.
Skipped: screen-ai is a proprietary Google binary, and ninja/siso/reclient
would shadow the build tools the builder image provides. Each dep is stamped
under .browser-deps/ only after a complete install, so an interrupted fetch is
redone rather than kept.

Ported from glim-sh/cuttle packages/browser/build/build-linux.sh (MIT).

Usage: fetch-cipd-deps.py <src-dir> <path/to/cipd>
"""
import collections
import hashlib
import json
import os
import subprocess
import sys
import tarfile
import urllib.request

src, cipd = sys.argv[1], sys.argv[2]
# Matched anywhere in the path: recursedeps carry their own copies.
skip = ("third_party/screen-ai/", "third_party/ninja/", "third_party/siso/", "buildtools/reclient/")
plat = {"${{platform}}": "linux-amd64", "${{arch}}": "amd64", "${{os}}": "linux"}


# DEPS files are Python, and gclient itself executes them and evaluates their
# conditions. They come from the sha-pinned source tree we compile anyway, so
# this trusts nothing the build does not already.
def load(path):
    g = {"Str": str}
    g["Var"] = lambda k: g["vars"][k]
    exec(open(path).read(), g)
    return g


def fetch_gcs(dep, dest):
    # What gclient does for a gcs dep: fetch each object from the public bucket,
    # verify its sha256, and unpack it if it is a tarball.
    print(f"  gcs {os.path.relpath(dest, src)}", flush=True)
    os.makedirs(dest, exist_ok=True)
    for o in dep["objects"]:
        url = f"https://storage.googleapis.com/{dep['bucket']}/{o['object_name']}"
        data = urllib.request.urlopen(url, timeout=300).read()
        if hashlib.sha256(data).hexdigest() != o["sha256sum"]:
            sys.exit(f"sha256 mismatch for {url}")
        # object_name can carry a bucket path; gclient writes the basename.
        out = os.path.join(dest, o.get("output_file") or os.path.basename(o["object_name"]))
        with open(out, "wb") as f:
            f.write(data)
        if tarfile.is_tarfile(out):
            with tarfile.open(out) as t:
                t.extractall(dest, filter="data")
            os.remove(out)
        else:
            os.chmod(out, 0o755)


def write_stamp(stamp, spec):
    os.makedirs(os.path.dirname(stamp), exist_ok=True)
    with open(stamp, "w") as f:
        f.write(spec)


def emit(g, prefix):
    env = collections.defaultdict(bool)
    env.update({k: v for k, v in g.get("vars", {}).items() if isinstance(v, (bool, str))})
    for k in [k for k in env if k.startswith("checkout_")]:
        env[k] = False
    env.update(non_git_source=True, build_with_chromium=True, checkout_linux=True,
               checkout_x64=True, host_os="linux", host_cpu="x64")
    for path, dep in g.get("deps", {}).items():
        if not isinstance(dep, dict) or dep.get("dep_type") not in ("cipd", "gcs"):
            continue
        cond = dep.get("condition", "True")
        rel = os.path.join(prefix, path.removeprefix("src/"))
        if "non_git_source" not in cond or not eval(cond, {}, env) or any(k in rel + "/" for k in skip):
            continue
        stamp = os.path.join(src, ".browser-deps", rel.replace("/", "__"))
        spec = json.dumps(dep, sort_keys=True)
        if os.path.isfile(stamp) and open(stamp).read() == spec:
            continue
        if dep["dep_type"] == "gcs":
            fetch_gcs(dep, os.path.join(src, rel))
            write_stamp(stamp, spec)
            continue
        pkgs = []
        for pkg in dep["packages"]:
            name = pkg["package"]
            for k, v in plat.items():
                name = name.replace(k, v)
            pkgs.append(f"{name} {pkg['version']}\n")
        # One cipd root per dep dir: `cipd ensure` is declarative for its root
        # and removes anything there not in the file, so a shared root would
        # delete every dep installed by an earlier run.
        print(f"  cipd ensure {rel}", flush=True)
        subprocess.run([cipd, "ensure", "-root", os.path.join(src, rel), "-ensure-file", "-"],
                       input="".join(pkgs), text=True, check=True, stdout=subprocess.DEVNULL)
        write_stamp(stamp, spec)


top = load(os.path.join(src, "DEPS"))
emit(top, "")
# gclient also evaluates the DEPS of every recursedep (devtools-frontend's
# esbuild, Dawn's Go, ...); with use_relative_paths their keys are repo-relative.
for rd in top.get("recursedeps", []):
    rd, name = (rd, "DEPS") if isinstance(rd, str) else rd
    sub = rd.removeprefix("src/")
    f = os.path.join(src, sub, name)
    if os.path.isfile(f):
        g = load(f)
        emit(g, sub if g.get("use_relative_paths") else "")
