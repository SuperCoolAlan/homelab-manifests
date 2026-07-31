#!/usr/bin/env python3
"""Stage the qbt store into the media dataset, hardlinking library dupes.

Reads /store (old qbt store, read-only), writes /media/torrents.
Files whose exact content already exists under /media/film or /media/tv are
hardlinked from the library instead of copied. Idempotent: existing
same-size destination files are skipped.
"""
import os
import sys
import time

STORE = "/store"
MEDIA = "/media"
DEST = os.path.join(MEDIA, "torrents")
LIB_DIRS = [os.path.join(MEDIA, "film"), os.path.join(MEDIA, "tv")]
CHUNK = 4 * 1024 * 1024
MIN_FREE_GIB = 100  # abort copies if the media filesystem drops below this

DRY_RUN = "--dry-run" in sys.argv
INCLUDE_INCOMPLETE = "--include-incomplete" in sys.argv
SKIP_TOP = set() if INCLUDE_INCOMPLETE else {"incomplete"}

# --bwlimit=N caps total read throughput at N MiB/s so the staging pass
# doesn't saturate the TrueNAS mirror and starve every NFS-backed app
# (that happened; pool1 pegged at ~430 read ops/s and all UIs crawled).
BWLIMIT = 40.0
for arg in sys.argv:
    if arg.startswith("--bwlimit="):
        BWLIMIT = float(arg.split("=", 1)[1])
_pace = {"t": time.monotonic()}


def paced(nbytes):
    """Sleep long enough that cumulative reads stay under BWLIMIT MiB/s."""
    if BWLIMIT <= 0:
        return
    _pace["t"] += nbytes / (BWLIMIT * 2**20)
    delay = _pace["t"] - time.monotonic()
    if delay > 0:
        time.sleep(delay)
    else:
        _pace["t"] = time.monotonic()


def free_gib():
    st = os.statvfs(MEDIA)
    return st.f_bavail * st.f_frsize / 2**30


def build_index():
    idx = {}
    t0 = time.time()
    n = 0
    for lib in LIB_DIRS:
        for root, _dirs, files in os.walk(lib):
            for f in files:
                p = os.path.join(root, f)
                try:
                    idx.setdefault(os.stat(p).st_size, []).append(p)
                    n += 1
                except OSError:
                    pass
    print(f"library index: {n} files in {time.time()-t0:.0f}s", flush=True)
    return idx


def same_content(a, b):
    with open(a, "rb") as fa, open(b, "rb") as fb:
        while True:
            ca = fa.read(CHUNK)
            cb = fb.read(CHUNK)
            paced(len(ca) + len(cb))
            if ca != cb:
                return False
            if not ca:
                return True


def paced_copy(src, dst):
    with open(src, "rb") as fs, open(dst, "wb") as fd:
        while True:
            chunk = fs.read(CHUNK)
            if not chunk:
                break
            fd.write(chunk)
            paced(len(chunk))


def main():
    idx = build_index()
    linked = copied = skipped = 0
    linked_b = copied_b = 0
    if not DRY_RUN:
        os.makedirs(DEST, exist_ok=True)
    for top in sorted(os.listdir(STORE)):
        if top in SKIP_TOP or top == "torrents":
            continue
        src_top = os.path.join(STORE, top)
        walk = os.walk(src_top) if os.path.isdir(src_top) else [(STORE, [], [top])]
        for root, _dirs, files in walk:
            for f in files:
                src = os.path.join(root, f)
                rel = os.path.relpath(src, STORE)
                dst = os.path.join(DEST, rel)
                try:
                    size = os.stat(src).st_size
                except OSError as e:
                    print(f"SKIP unreadable {rel}: {e}", flush=True)
                    continue
                if os.path.exists(dst) and os.stat(dst).st_size == size:
                    skipped += 1
                    continue
                match = None
                for cand in idx.get(size, []):
                    try:
                        if same_content(src, cand):
                            match = cand
                            break
                    except OSError:
                        continue
                if DRY_RUN:
                    if match:
                        linked += 1
                        linked_b += size
                    else:
                        copied += 1
                        copied_b += size
                    continue
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                if match:
                    if os.path.exists(dst):
                        os.remove(dst)
                    os.link(match, dst)
                    linked += 1
                    linked_b += size
                else:
                    if free_gib() < MIN_FREE_GIB:
                        print(f"ABORT: free space {free_gib():.0f} GiB < {MIN_FREE_GIB} GiB floor", flush=True)
                        sys.exit(2)
                    part = dst + ".part"
                    paced_copy(src, part)
                    os.rename(part, dst)
                    copied += 1
                    copied_b += size
        print(f"done: {top}", flush=True)
    mode = "DRY RUN — would " if DRY_RUN else ""
    print(f"{mode}link: {linked} files / {linked_b/2**30:.1f} GiB", flush=True)
    print(f"{mode}copy: {copied} files / {copied_b/2**30:.1f} GiB", flush=True)
    print(f"skipped (already staged): {skipped}", flush=True)


if __name__ == "__main__":
    main()
