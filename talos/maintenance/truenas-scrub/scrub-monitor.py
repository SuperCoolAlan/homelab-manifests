#!/usr/bin/env python3
"""Start a ZFS scrub on a TrueNAS pool and stream progress until it finishes.

Idempotent: if a scrub is already running on the pool, this attaches to it and
monitors rather than starting a second one.

Exit codes:
  0  scrub finished with zero errors
  1  scrub finished but reported errors
  2  scrub was cancelled, or an unrecoverable API problem occurred

Env:
  TRUENAS_URL       default https://truenas.asandov.local/api/v2.0
  TRUENAS_API_KEY   required
  POOL_NAME         default ST6000NM0095-pool1
  POLL_INTERVAL     seconds between progress lines, default 60
  VERIFY_TLS        "true" to enforce cert validation, default false (self-signed)
"""
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request

BASE = os.environ.get("TRUENAS_URL", "https://truenas.asandov.local/api/v2.0")
KEY = os.environ.get("TRUENAS_API_KEY", "")
POOL = os.environ.get("POOL_NAME", "ST6000NM0095-pool1")
INTERVAL = int(os.environ.get("POLL_INTERVAL", "60"))
VERIFY = os.environ.get("VERIFY_TLS", "false").lower() == "true"

if not KEY:
    print("FATAL: TRUENAS_API_KEY is empty", flush=True)
    sys.exit(2)

CTX = ssl.create_default_context()
if not VERIFY:
    CTX.check_hostname = False
    CTX.verify_mode = ssl.CERT_NONE


def log(msg=""):
    if msg == "":
        print("", flush=True)
    else:
        print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)


def api(path, method="GET", body=None, retries=3):
    """Call the TrueNAS REST API. Transient failures are retried."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        f"{BASE}{path}",
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {KEY}",
            "Content-Type": "application/json",
        },
    )
    last = None
    for attempt in range(1, retries + 1):
        try:
            with urllib.request.urlopen(req, context=CTX, timeout=60) as r:
                raw = r.read().decode().strip()
                return json.loads(raw) if raw else None
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError) as e:
            last = e
            if attempt < retries:
                log(f"  ! API {method} {path} failed ({e}); retry {attempt}/{retries - 1} in 10s")
                time.sleep(10)
    raise RuntimeError(f"API {method} {path} failed after {retries} attempts: {last}")


def human(n):
    n = float(n or 0)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} PiB"


def dur(secs):
    s = int(secs or 0)
    h, rem = divmod(s, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}h {m:02d}m"
    if m:
        return f"{m}m {s:02d}s"
    return f"{s}s"


def bar(pct, width=36):
    filled = max(0, min(width, int(round(width * pct / 100.0))))
    return "#" * filled + "-" * (width - filled)


def get_pool():
    pools = api("/pool") or []
    for p in pools:
        if p["name"] == POOL:
            return p
    raise RuntimeError(f"pool {POOL!r} not found on {BASE}")


def describe_topology(pool):
    lines = []

    def walk(vdevs, indent=4):
        for v in vdevs:
            name = v.get("name") or v.get("type") or "?"
            disk = v.get("disk") or ""
            lines.append(f"{' ' * indent}{name:<42} {v.get('status', '?'):<10} {disk}")
            walk(v.get("children") or [], indent + 2)

    walk((pool.get("topology") or {}).get("data") or [])
    return lines


def progress(scan):
    """Return (percent, detail-string) for a scan object."""
    issued = scan.get("bytes_issued") or 0
    total = scan.get("bytes_to_process") or 0
    pct = (issued / total * 100.0) if total else 0.0
    eta = scan.get("total_secs_left")
    detail = f"{human(issued)} / {human(total)}"
    # ZFS emits a garbage estimate (years) until it has issued real work, so
    # suppress anything implausible rather than printing "13475379370h".
    if eta and 0 < eta < 7 * 24 * 3600:
        detail += f"  eta {dur(eta)}"
    return pct, detail


def main():
    log("=" * 78)
    log(f"TrueNAS scrub monitor  |  pool: {POOL}")
    log(f"endpoint: {BASE}   poll every {INTERVAL}s")
    log("=" * 78)

    pool = get_pool()
    log(f"pool id={pool['id']}  status={pool['status']}  healthy={pool.get('healthy')}")
    log(f"capacity: {human(pool.get('allocated'))} allocated of {human(pool.get('size'))}")
    log("topology:")
    for line in describe_topology(pool):
        log(line)
    log("")

    if pool["status"] != "ONLINE":
        log(f"WARNING: pool status is {pool['status']}, not ONLINE. Scrubbing anyway.")
        log("")

    scan = pool.get("scan") or {}
    already = scan.get("function") == "SCRUB" and scan.get("state") == "SCANNING"

    if already:
        log("A scrub is ALREADY RUNNING on this pool - attaching to it.")
    else:
        log("Starting scrub ...")
        api("/pool/scrub/run", method="POST", body={"name": POOL, "threshold": 0})
        log("Scrub start request accepted.")
        time.sleep(10)

    log("")
    log("-" * 78)

    started = time.time()
    last_state = None
    ticks = 0

    while True:
        pool = get_pool()
        scan = pool.get("scan") or {}
        state = scan.get("state")
        func = scan.get("function")
        errors = scan.get("errors")

        if func != "SCRUB":
            # A resilver can pre-empt a scrub; report it rather than silently waiting.
            log(f"NOTE: active scan is {func}, not SCRUB (state={state})")

        if state != last_state:
            log(f"state -> {state}")
            last_state = state

        if state in ("FINISHED", "CANCELED", "CANCELLED"):
            elapsed = time.time() - started
            log("-" * 78)
            log("")
            if state.startswith("CANCEL"):
                log(f"RESULT: scrub was {state} after {dur(elapsed)} of monitoring")
                return 2
            pct, detail = progress(scan)
            log(f"RESULT: scrub FINISHED  |  {detail}")
            log(f"        monitored for {dur(elapsed)}   errors reported: {errors}")
            log(f"        pool status: {pool['status']}  healthy: {pool.get('healthy')}")
            log("")
            if errors:
                log(f"*** {errors} ERROR(S) FOUND - investigate before relying on this pool ***")
                return 1
            log("*** Zero errors. Pool data verified. ***")
            log("=" * 78)
            return 0

        pct, detail = progress(scan)
        ticks += 1
        log(f"[{bar(pct)}] {pct:5.1f}%  {detail}  errors={errors}")

        # Every 30 ticks, restate the header so a long log stays readable.
        if ticks % 30 == 0:
            log(f"  ... still scrubbing {POOL}; elapsed {dur(time.time() - started)}")

        time.sleep(INTERVAL)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        log("interrupted")
        sys.exit(2)
    except Exception as exc:  # noqa: BLE001 - top-level reporter
        log(f"FATAL: {exc}")
        sys.exit(2)
