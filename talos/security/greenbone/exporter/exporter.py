"""Creates the scan objects in scan.json if missing, and serves the latest report of each task as Prometheus metrics."""
import calendar
import json
import os
import threading
import time
import traceback
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from gvm.connections import UnixSocketConnection
from gvm.protocols.gmp import GMP
from gvm.transforms import EtreeCheckCommandTransform

SOCKET = os.environ.get("GVMD_SOCKET", "/run/gvmd/gvmd.sock")
USERNAME = os.environ.get("GMP_USERNAME", "admin")
PASSWORD = os.environ["GMP_PASSWORD"]
CONFIG = os.environ.get("SCAN_CONFIG", "/exporter/scan.json")
INTERVAL = int(os.environ.get("INTERVAL", "300"))
PORT = int(os.environ.get("PORT", "9966"))
# Results below this QoD are mostly version-guess noise; 70 is GSA's own default filter.
RESULT_FILTER = "apply_overrides=1 min_qod=70 severity>0.0 rows=-1 first=1"
MANAGED = "Managed by greenbone-exporter from git (talos/security/greenbone/exporter/scan.json)"

state = {"findings": "", "tasks": "", "feeds": "", "up": 0, "reconciled": 0, "last_success": 0.0}
lock = threading.Lock()


def esc(value):
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def metric(name, labels, value):
    inner = ",".join(f'{k}="{esc(v)}"' for k, v in labels.items())
    return f"{name}{{{inner}}} {value}\n"


def ts(iso):
    if not iso:
        return None
    return datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()


def ids_by_name(response, tag):
    return {e.findtext("name"): e.get("id") for e in response.findall(tag)}


def ical(schedule):
    return (
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//homelab//greenbone-exporter//EN\r\n"
        f"BEGIN:VEVENT\r\nUID:{schedule['name']}\r\nDTSTAMP:{schedule['dtstart']}\r\n"
        f"DTSTART:{schedule['dtstart']}\r\nRRULE:{schedule['rrule']}\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    )


def reconcile(gmp, cfg):
    """Create-only: an existing object with the same name is left as is."""
    config_id = ids_by_name(gmp.get_scan_configs(filter_string="rows=-1"), "config").get(cfg["scan_config"])
    port_list_id = ids_by_name(gmp.get_port_lists(filter_string="rows=-1"), "port_list").get(cfg["port_list"])
    scanner_id = ids_by_name(gmp.get_scanners(filter_string="rows=-1"), "scanner").get(cfg["scanner"])
    if not (config_id and port_list_id and scanner_id):
        # Scan configs and port lists arrive with the feed, which can take hours on first start.
        print("feed objects not loaded yet; skipping reconcile", flush=True)
        return 0

    schedule = cfg["schedule"]
    schedule_id = ids_by_name(gmp.get_schedules(filter_string="rows=-1"), "schedule").get(schedule["name"])
    if not schedule_id:
        schedule_id = gmp.create_schedule(schedule["name"], ical(schedule), schedule["timezone"], comment=MANAGED).get("id")
        print(f"created schedule {schedule['name']}", flush=True)

    targets = ids_by_name(gmp.get_targets(filter_string="rows=-1"), "target")
    tasks = ids_by_name(gmp.get_tasks(filter_string="rows=-1"), "task")
    for target in cfg["targets"]:
        name = target["name"]
        if name not in targets:
            targets[name] = gmp.create_target(
                name,
                hosts=target["hosts"],
                exclude_hosts=target.get("exclude_hosts") or None,
                port_list_id=port_list_id,
                alive_test=cfg["alive_test"],
                comment=MANAGED,
            ).get("id")
            print(f"created target {name}", flush=True)
        if name not in tasks:
            gmp.create_task(
                name,
                config_id,
                targets[name],
                scanner_id,
                schedule_id=schedule_id,
                preferences=cfg.get("preferences"),
                comment=MANAGED,
            )
            print(f"created task {name}", flush=True)
    return 1


def collect_feeds(gmp):
    out = ""
    for feed in gmp.get_feeds().findall("feed"):
        version = feed.findtext("version") or ""
        labels = {"type": feed.findtext("type") or "", "name": feed.findtext("name") or ""}
        out += metric("greenbone_feed_syncing", labels, int(feed.find("currently_syncing") is not None))
        if len(version) == 12 and version.isdigit():
            out += metric("greenbone_feed_version_timestamp_seconds", labels, calendar.timegm(time.strptime(version, "%Y%m%d%H%M")))
    return out


def collect_tasks(gmp):
    tasks_out, findings_out = "", ""
    for task in gmp.get_tasks(filter_string="rows=-1").findall("task"):
        name = task.findtext("name")
        tasks_out += metric("greenbone_task_status", {"task": name, "status": task.findtext("status") or ""}, 1)
        tasks_out += metric("greenbone_task_progress", {"task": name}, task.findtext("progress") or 0)
        last = task.find("last_report/report")
        if last is None:
            continue
        scan_end = ts(last.findtext("scan_end"))
        if scan_end:
            tasks_out += metric("greenbone_task_last_scan_end_timestamp_seconds", {"task": name}, scan_end)

        report = gmp.get_report(last.get("id"), filter_string=RESULT_FILTER, details=True, ignore_pagination=True).find("report/report")
        if report is None:
            continue
        tasks_out += metric("greenbone_task_hosts", {"task": name}, report.findtext("hosts/count") or 0)
        worst = {}
        seen = {}
        for result in report.findall("results/result"):
            host_el = result.find("host")
            host = (host_el.text or "").strip() if host_el is not None else ""
            hostname = result.findtext("host/hostname") or ""
            nvt = result.find("nvt")
            severity = float(result.findtext("severity") or 0)
            cves = [ref.get("id") for ref in nvt.findall("refs/ref") if ref.get("type") == "cve"]
            labels = {
                "task": name,
                "host": host,
                "hostname": hostname,
                "port": result.findtext("port") or "",
                "oid": nvt.get("oid") or "",
                "name": nvt.findtext("name") or "",
                "threat": result.findtext("threat") or "",
                "cve": ",".join(cves[:3]) + (",..." if len(cves) > 3 else ""),
            }
            key = tuple(labels.values())
            seen[key] = max(severity, seen.get(key, 0.0))
            worst[(host, hostname)] = max(severity, worst.get((host, hostname), 0.0))
        for key, severity in seen.items():
            findings_out += metric("greenbone_result_severity", dict(zip(
                ("task", "host", "hostname", "port", "oid", "name", "threat", "cve"), key)), severity)
        for (host, hostname), severity in worst.items():
            findings_out += metric("greenbone_host_max_severity", {"task": name, "host": host, "hostname": hostname}, severity)
    return tasks_out, findings_out


def loop():
    with open(CONFIG) as f:
        cfg = json.load(f)
    while True:
        try:
            with GMP(UnixSocketConnection(path=SOCKET, timeout=600), transform=EtreeCheckCommandTransform()) as gmp:
                gmp.authenticate(USERNAME, PASSWORD)
                reconciled = reconcile(gmp, cfg)
                feeds = collect_feeds(gmp)
                tasks, findings = collect_tasks(gmp)
            with lock:
                state.update(feeds=feeds, tasks=tasks, findings=findings, up=1, reconciled=reconciled, last_success=time.time())
        except Exception:
            # Keep the last good findings so a gvmd restart doesn't resolve and re-fire every alert.
            traceback.print_exc()
            with lock:
                state["up"] = 0
        time.sleep(INTERVAL)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_error(404)
            return
        with lock:
            body = (
                f"greenbone_up {state['up']}\n"
                f"greenbone_reconcile_complete {state['reconciled']}\n"
                f"greenbone_last_success_timestamp_seconds {state['last_success']}\n"
                + state["feeds"] + state["tasks"] + state["findings"]
            ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    threading.Thread(target=loop, daemon=True).start()
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
