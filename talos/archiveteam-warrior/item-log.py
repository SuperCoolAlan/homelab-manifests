# Mirrors the warrior web UI's per-item output to stdout so VictoriaLogs keeps it; seesaw never logs items to stdout.
import json
import sys

from tornado import gen, ioloop, websocket

URL = "ws://localhost:8001/websocket"
SKIP = {"bandwidth", "timestamp", "warrior.projects_loaded", "instance_id"}

project = "-"
task_names = {}
item_names = {}
printed = {}


def log(item_id, text):
    name = item_names.get(item_id) or item_id
    for line in text.splitlines():
        if line.strip():
            print("project=%s item=%s %s" % (project, name, line), flush=True)


def emit_output(item_id, text):
    printed[item_id] = printed.get(item_id, 0) + len(text)
    log(item_id, text)


def snapshot(msg):
    global project
    if not msg:
        project = "-"
        return
    project = msg["project"]["title"]
    for it in msg["items"]:
        iid = it["id"]
        if it.get("name") not in (None, "New item"):
            item_names[iid] = it["name"]
        for t in it.get("tasks", []):
            task_names[t["id"]] = t["name"]
        out = it.get("output", "")
        # Snapshots replay full output on every connect; print only what's new.
        new = out[printed.get(iid, 0):]
        if new:
            emit_output(iid, new)


def handle(ev, msg):
    if ev == "project.refresh":
        snapshot(msg)
    elif ev == "item.output":
        emit_output(msg["item_id"], msg["data"])
    elif ev == "item.task_status":
        log(msg["item_id"], "task %s: %s -> %s" % (
            task_names.get(msg["task_id"], msg["task_id"]),
            msg["old_status"], msg["new_status"]))
    elif ev == "item.update_name":
        item_names[msg["item_id"]] = msg["new_name"]
        log(msg["item_id"], "named %s" % msg["new_name"])
    elif ev in ("item.complete", "item.fail", "item.cancel"):
        log(msg["item_id"], ev.split(".")[1].upper())
        printed.pop(msg["item_id"], None)
    else:
        print("project=%s event=%s %s" % (project, ev, json.dumps(msg)[:2000]), flush=True)


@gen.coroutine
def main():
    while True:
        try:
            conn = yield websocket.websocket_connect(URL)
            print("connected to %s" % URL, flush=True)
            while True:
                raw = yield conn.read_message()
                if raw is None:
                    break
                d = json.loads(raw)
                if d.get("event_name") not in SKIP:
                    handle(d.get("event_name"), d.get("message"))
        except Exception as e:
            print("websocket error: %r" % (e,), file=sys.stderr, flush=True)
        yield gen.sleep(5)


if __name__ == "__main__":
    ioloop.IOLoop.current().run_sync(main)
