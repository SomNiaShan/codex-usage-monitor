import datetime as _dt
import json
import sqlite3
import sys


def _normalize_limit(limit):
    if not isinstance(limit, dict):
        return None

    reset_at = limit.get("reset_at")
    return {
        "used_percent": limit.get("used_percent"),
        "window_minutes": limit.get("window_minutes"),
        "reset_after_seconds": limit.get("reset_after_seconds"),
        "reset_at": reset_at,
        "resets_at": reset_at,
    }


def _extract_rate_limit_events(body):
    marker = "websocket event:"
    decoder = json.JSONDecoder()
    search_from = 0

    while True:
        idx = body.find(marker, search_from)
        if idx < 0:
            return

        payload_start = idx + len(marker)
        json_offset = body.find("{", payload_start)
        if json_offset < 0:
            return

        try:
            event, end = decoder.raw_decode(body[json_offset:])
        except json.JSONDecodeError:
            search_from = payload_start
            continue

        if isinstance(event, dict) and event.get("type") == "codex.rate_limits":
            yield event

        search_from = json_offset + max(end, 1)


def main():
    if len(sys.argv) != 2:
        return 2

    db_path = sys.argv[1]
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=0.5)
    try:
        rows = con.execute(
            """
            select id, ts, feedback_log_body
            from logs
            where target = 'codex_api::endpoint::responses_websocket'
              and feedback_log_body like '%codex.rate_limits%'
            order by ts desc, id desc
            limit 200
            """
        ).fetchall()
    finally:
        con.close()

    for _row_id, ts, body in rows:
        events = list(_extract_rate_limit_events(body or ""))
        if not events:
            continue
        event = events[-1]

        limits = event.get("rate_limits") or {}
        ts_seconds = ts / 1000 if ts and ts > 10**12 else ts
        timestamp = (
            _dt.datetime.fromtimestamp(ts_seconds).astimezone().isoformat()
            if ts_seconds
            else None
        )

        print(
            json.dumps(
                {
                    "source": "logs_2.sqlite",
                    "timestamp": timestamp,
                    "rate_limits": {
                        "limit_id": "codex",
                        "plan_type": event.get("plan_type"),
                        "allowed": limits.get("allowed"),
                        "limit_reached": limits.get("limit_reached"),
                        "primary": _normalize_limit(limits.get("primary")),
                        "secondary": _normalize_limit(limits.get("secondary")),
                    },
                },
                ensure_ascii=False,
                separators=(",", ":"),
            )
        )
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
