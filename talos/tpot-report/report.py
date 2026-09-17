"""Report honeypot attackers to AbuseIPDB.

Runs in-cluster so the API key never touches the honeypot: the hive is read
through its own nginx (basic auth), and only aggregate counts leave here.
"""

import base64
import ipaddress
import json
import os
import ssl
import urllib.error
import urllib.parse
import urllib.request

ES = os.environ["HIVE_URL"].rstrip("/") + "/es"
AUTH = (os.environ["HIVE_USER"], os.environ["HIVE_PASSWORD"])
KEY = os.environ["ABUSEIPDB_KEY"]
WINDOW = os.environ.get("WINDOW", "now-70m")
# Free tier allows 1000 reports/day; hourly runs leave room to spare.
MAX_REPORTS = int(os.environ.get("MAX_REPORTS", "40"))
# Honeypots that see real credential attempts, not just connections.
HONEYPOTS = ["Cowrie", "Heralding", "Dionaea"]

# The hive serves its own self-signed cert; the connection stays inside the cluster.
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def es_search(body):
    req = urllib.request.Request(
        f"{ES}/logstash-*/_search",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    token = base64.b64encode(f"{AUTH[0]}:{AUTH[1]}".encode()).decode()
    req.add_header("Authorization", f"Basic {token}")
    with urllib.request.urlopen(req, timeout=30, context=CTX) as r:
        return json.load(r)


def reportable(ip):
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return not (a.is_private or a.is_loopback or a.is_reserved or a.is_link_local)


def main():
    res = es_search(
        {
            "size": 0,
            "query": {
                "bool": {
                    "filter": [
                        {"range": {"@timestamp": {"gte": WINDOW}}},
                        {"terms": {"type.keyword": HONEYPOTS}},
                    ]
                }
            },
            "aggs": {
                "ips": {
                    "terms": {"field": "src_ip.keyword", "size": MAX_REPORTS * 3},
                    "aggs": {"hp": {"terms": {"field": "type.keyword", "size": 5}}},
                }
            },
        }
    )

    buckets = res.get("aggregations", {}).get("ips", {}).get("buckets", [])
    attackers = [b for b in buckets if reportable(b["key"])][:MAX_REPORTS]
    print(f"{len(buckets)} source IPs in window, reporting {len(attackers)}")

    sent = failed = 0
    for b in attackers:
        ip, hits = b["key"], b["doc_count"]
        seen = ",".join(h["key"] for h in b["hp"]["buckets"])
        # No sensor name, region or IP: the comment says what happened, not where.
        comment = f"T-Pot honeypot: {hits} credential/exploit attempts ({seen}) in the last hour"
        data = urllib.parse.urlencode(
            {"ip": ip, "categories": "18,22", "comment": comment}
        ).encode()
        req = urllib.request.Request(
            "https://api.abuseipdb.com/api/v2/report",
            data=data,
            headers={"Key": KEY, "Accept": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                json.load(r)
                sent += 1
        except urllib.error.HTTPError as e:
            # 429 means the daily quota is gone; stop rather than burn the rest of the run.
            body = e.read().decode()[:200]
            print(f"{ip}: HTTP {e.code} {body}")
            failed += 1
            if e.code == 429:
                break
        except Exception as e:  # noqa: BLE001 - keep going on single-IP failures
            print(f"{ip}: {e}")
            failed += 1

    print(f"reported={sent} failed={failed}")


if __name__ == "__main__":
    main()
