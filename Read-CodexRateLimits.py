import datetime as _dt
import json
import sqlite3
import sys
import time


def _normalize_limit(limit):
    if not isinstance(limit, dict):
        return None

    reset_at = limit.get("reset_at")
    if reset_at is None:
        reset_at = limit.get("resets_at")
    return {
        "used_percent": limit.get("used_percent"),
        "window_minutes": limit.get("window_minutes"),
        "reset_after_seconds": limit.get("reset_after_seconds"),
        "reset_at": reset_at,
        "resets_at": reset_at,
    }


def _normalize_epoch(value):
    if value is None:
        return None

    try:
        epoch = float(value)
    except (TypeError, ValueError):
        return None

    if epoch > 10**12:
        epoch = epoch / 1000

    return epoch


def _limit_score(limit, expected_window, now):
    if not isinstance(limit, dict):
        return -1000

    score = 0

    try:
        window_minutes = float(limit.get("window_minutes"))
        if abs(window_minutes - expected_window) < 0.001:
            score += 30
    except (TypeError, ValueError):
        pass

    reset_at = _normalize_epoch(limit.get("reset_at") or limit.get("resets_at"))
    reset_after_seconds = limit.get("reset_after_seconds")

    try:
        if reset_after_seconds is not None and float(reset_after_seconds) >= -60:
            score += 20
    except (TypeError, ValueError):
        pass

    if reset_at is not None:
        if reset_at >= now - 60:
            score += 40
        else:
            # Expired reset times are usually stale quota snapshots.
            score -= 80

    try:
        used_percent = float(limit.get("used_percent"))
        if 0 <= used_percent <= 100:
            score += 5
    except (TypeError, ValueError):
        pass

    return score


def _extract_rate_limit_events(body):
    decoder = json.JSONDecoder()
    search_from = 0

    while True:
        json_offset = body.find("{", search_from)
        if json_offset < 0:
            return

        try:
            event, end = decoder.raw_decode(body[json_offset:])
        except json.JSONDecodeError:
            search_from = json_offset + 1
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
            select id, ts, target, feedback_log_body
            from logs
            where feedback_log_body like '%codex.rate_limits%'
            order by ts desc, id desc
            limit 1000
            """
        ).fetchall()
    finally:
        con.close()

    candidates = []
    now = time.time()

    for row_index, (_row_id, ts, target, body) in enumerate(rows):
        events = list(_extract_rate_limit_events(body or ""))
        for event_index, event in enumerate(events):
            limits = event.get("rate_limits") or {}
            primary = _normalize_limit(limits.get("primary"))
            secondary = _normalize_limit(limits.get("secondary"))

            ts_seconds = ts / 1000 if ts and ts > 10**12 else ts
            timestamp = (
                _dt.datetime.fromtimestamp(ts_seconds).astimezone().isoformat()
                if ts_seconds
                else None
            )

            score = 0
            if target == "codex_api::endpoint::responses_websocket":
                score += 5
            if event.get("type") == "codex.rate_limits":
                score += 10
            if limits.get("allowed") is not False:
                score += 3
            score += _limit_score(primary, 300, now)
            score += _limit_score(secondary, 10080, now)

            # Newer rows are still important, but stale reset times should not win.
            recency_rank = len(rows) - row_index
            score += recency_rank / max(len(rows), 1)

            candidates.append(
                {
                    "score": score,
                    "row_index": row_index,
                    "event_index": event_index,
                    "timestamp": timestamp,
                    "rate_limits": {
                        "limit_id": "codex",
                        "plan_type": event.get("plan_type"),
                        "allowed": limits.get("allowed"),
                        "limit_reached": limits.get("limit_reached"),
                        "primary": primary,
                        "secondary": secondary,
                    },
                }
            )

    if candidates:
        best = max(
            candidates,
            key=lambda item: (
                item["score"],
                -item["row_index"],
                item["event_index"],
            ),
        )

        print(
            json.dumps(
                {
                    "source": "logs_2.sqlite",
                    "timestamp": best["timestamp"],
                    "rate_limits": best["rate_limits"],
                },
                ensure_ascii=False,
                separators=(",", ":"),
            )
        )
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
