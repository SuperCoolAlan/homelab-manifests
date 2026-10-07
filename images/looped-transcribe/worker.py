"""Transcribe Looped audio segments from Garage into VictoriaLogs.

The bucket is the queue: incoming/ is pending, done/ is transcribed, failed/ gave up after MAX_ATTEMPTS.
"""

import datetime as dt
import json
import logging
import os
import tempfile
import time
import urllib.request

import boto3
from faster_whisper import WhisperModel
from prometheus_client import Counter, Gauge, start_http_server

BUCKET = os.environ.get("BUCKET", "looped-audio")
S3_ENDPOINT = os.environ["S3_ENDPOINT"]
VLOGS_URL = os.environ["VLOGS_URL"]
MODEL = os.environ.get("MODEL", "large-v3")
COMPUTE_TYPE = os.environ.get("COMPUTE_TYPE", "int8_float16")
LANGUAGE = os.environ.get("LANGUAGE") or None
MAX_ATTEMPTS = int(os.environ.get("MAX_ATTEMPTS", "3"))
KEEP_DAYS = float(os.environ.get("KEEP_DAYS", "7"))
POLL_S = float(os.environ.get("POLL_S", "30"))

log = logging.getLogger("transcribe")
CHUNKS = Counter("looped_transcribe_chunks_total", "Segments handled", ["result"])
AUDIO_SECONDS = Counter("looped_transcribe_audio_seconds_total", "Audio transcribed")
SPEECH_SEGMENTS = Counter("looped_transcribe_speech_segments_total", "Speech segments written to VictoriaLogs")
BACKLOG = Gauge("looped_transcribe_backlog", "Objects waiting in incoming/")
OLDEST = Gauge("looped_transcribe_oldest_pending_age_seconds", "Age of the oldest object in incoming/")
FAILED = Gauge("looped_transcribe_failed_objects", "Objects parked in failed/")


def keys(s3, prefix):
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=BUCKET, Prefix=prefix):
        yield from page.get("Contents", [])


def move(s3, key, dest):
    s3.copy_object(Bucket=BUCKET, Key=dest + key.split("/", 1)[1], CopySource={"Bucket": BUCKET, "Key": key})
    s3.delete_object(Bucket=BUCKET, Key=key)


def chunk_start(key):
    # capture.sh on the box names segments by their UTC start, e.g. incoming/20261006T190300Z.aac
    return dt.datetime.strptime(key.rsplit("/", 1)[1].split(".")[0], "%Y%m%dT%H%M%SZ").replace(tzinfo=dt.timezone.utc)


def transcribe(model, s3, key):
    start = chunk_start(key)
    with tempfile.NamedTemporaryFile(suffix=".aac") as f:
        s3.download_fileobj(BUCKET, key, f)
        f.flush()
        segments, info = model.transcribe(
            f.name, language=LANGUAGE, vad_filter=True, beam_size=5,
            # carrying text across segments lets one hallucination repeat for the rest of the chunk
            condition_on_previous_text=False,
        )
        segments = list(segments)
    lines = [
        json.dumps({
            "_time": (start + dt.timedelta(seconds=s.start)).isoformat().replace("+00:00", "Z"),
            "_msg": s.text.strip(),
            "site": "looped",
            "source": "audio",
            "chunk": key.rsplit("/", 1)[1],
            "offset_s": round(s.start, 2),
            "duration_s": round(s.end - s.start, 2),
            "language": info.language,
            "avg_logprob": round(s.avg_logprob, 3),
            "no_speech_prob": round(s.no_speech_prob, 3),
        })
        for s in segments if s.text.strip()
    ]
    if lines:
        req = urllib.request.Request(
            VLOGS_URL + "/insert/jsonline?_stream_fields=site,source",
            data="\n".join(lines).encode(), method="POST",
        )
        urllib.request.urlopen(req, timeout=30).read()
    AUDIO_SECONDS.inc(info.duration)
    SPEECH_SEGMENTS.inc(len(lines))
    return len(lines)


def prune(s3):
    cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=KEEP_DAYS)
    for obj in keys(s3, "done/"):
        if obj["LastModified"] < cutoff:
            s3.delete_object(Bucket=BUCKET, Key=obj["Key"])


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    # huggingface_hub logs every model-file request at INFO
    logging.getLogger("httpx").setLevel(logging.WARNING)
    start_http_server(9100)
    s3 = boto3.client("s3", endpoint_url=S3_ENDPOINT, region_name="garage")
    model = WhisperModel(MODEL, device="cuda", compute_type=COMPUTE_TYPE)
    log.info("model %s (%s) loaded", MODEL, COMPUTE_TYPE)
    attempts, last_prune = {}, 0.0
    while True:
        try:
            pending = sorted(o["Key"] for o in keys(s3, "incoming/"))
            BACKLOG.set(len(pending))
            OLDEST.set((dt.datetime.now(dt.timezone.utc) - chunk_start(pending[0])).total_seconds() if pending else 0)
            for key in pending:
                try:
                    n = transcribe(model, s3, key)
                    move(s3, key, "done/")
                    attempts.pop(key, None)
                    CHUNKS.labels("ok").inc()
                    log.info("%s: %d speech segments", key, n)
                except Exception:
                    attempts[key] = attempts.get(key, 0) + 1
                    log.exception("%s: attempt %d failed", key, attempts[key])
                    if attempts[key] >= MAX_ATTEMPTS:
                        move(s3, key, "failed/")
                        attempts.pop(key)
                        CHUNKS.labels("failed").inc()
                    else:
                        CHUNKS.labels("error").inc()
            FAILED.set(sum(1 for _ in keys(s3, "failed/")))
            if time.time() - last_prune > 3600:
                prune(s3)
                last_prune = time.time()
        except Exception:
            log.exception("pass failed")
        time.sleep(POLL_S)


if __name__ == "__main__":
    main()
