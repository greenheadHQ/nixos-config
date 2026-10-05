"""Card-specific inspection candidates from actual, undoable review history.

Ratings are observations, not diagnoses of a note or the learner. Replaying the
log instead of incrementing counters also handles native Undo and merged logs.
Only the optional reassessment anchor is stored on the card (and synced).
"""
from __future__ import annotations

from datetime import datetime, timedelta
import hashlib
import json
from typing import Callable

MODEL_NAME = "학습 Basic"
BASELINE_KEY = "dcb"
SCHEMA_VERSION = 1


class DifficultyError(ValueError):
    pass


def study_day(timestamp: int, rollover: int = 4) -> str:
    """Use local civil time, including historical DST, and Anki's rollover."""
    if type(rollover) is not int or not 0 <= rollover <= 23:
        raise DifficultyError("invalid-rollover")
    return (datetime.fromtimestamp(timestamp / 1000) - timedelta(hours=rollover)).date().isoformat()


def _trigger(rows: list[dict], *, learning: bool = False) -> bool:
    again = sum(r["ease"] == 1 for r in rows)
    hard = sum(r["ease"] == 2 for r in rows)
    return (again >= (3 if learning else 2) or hard >= (4 if learning else 3)
            or (again > 0 and hard > 0 and again + hard >= (4 if learning else 3)))


def _evidence(kind: str, rows: list[dict]) -> dict:
    delays = [r["late_days_estimate"] for r in rows if r.get("late_days_estimate") is not None]
    return {"kind": kind, "samples": len(rows), "again": sum(r["ease"] == 1 for r in rows),
            "hard": sum(r["ease"] == 2 for r in rows),
            "first_review_at": rows[0]["id"], "last_review_at": rows[-1]["id"],
            "late_days_estimate": max(delays) if delays else None}


def learning_boundary(row: dict) -> bool:
    # Early rescheduling Review is logged as type 3, but begins a new lapse
    # episode just like a due Review. Native preview logs fix factor=0; their
    # seconds-based lastIvl can still become positive across the day cutoff.
    return row["type"] in (1, 4, 5) or (row["type"] == 3 and row.get("lastIvl", 0) > 0
                                          and row.get("factor", 0) > 0)


def assess(rows: list[dict], *, card_type: int, cutoff: int = 0,
           day: Callable[[int], str] = study_day) -> list[dict]:
    """Replay in timestamp order; type=3 filtered/preview and ease=0 manual rows do not count.

    Rescheduling filtered-deck answers may have ordinary types 0/1/2: revlog
    cannot retrospectively identify their original deck. Do not claim otherwise.
    A recovery starts a fresh window without deleting or rewriting any logs.
    """
    if type(cutoff) is not int or cutoff < 0:
        raise DifficultyError("invalid-cutoff")
    ordered = sorted(rows, key=lambda r: r["id"])
    if len({r["id"] for r in ordered}) != len(ordered):
        raise DifficultyError("duplicate-review-id")
    recent, recovery = [], []
    review_active = False
    learning_rows = []
    learning_evidence = None
    previous = None
    for original in ordered:
        row = dict(original)
        valid = row["type"] in (0, 1, 2) and row["ease"] in (1, 2, 3, 4)
        # A review begins a new learning/relearning episode. A manual change
        # can also reset its state; it is a boundary, never a counted answer.
        if learning_boundary(row):
            learning_rows.clear()
            learning_evidence = None
        if valid and row["type"] == 1:
            elapsed = None
            if previous is not None and previous["type"] in (0, 1, 2) and previous["ease"] in (1, 2, 3, 4):
                elapsed = (datetime.fromisoformat(day(row["id"]))
                           - datetime.fromisoformat(day(previous["id"]))).days
            # Historical due dates are not stored in revlog. This is explicitly
            # an interval-based estimate, not a claim about the exact due date.
            interval = row.get("lastIvl", 0)
            row["late_days_estimate"] = (max(0, elapsed - interval)
                                         if elapsed is not None and interval > 0 else None)
            # Count actual rescheduling Review answers, including more than one
            # on a study day. Presentation time is not the native grading time.
            if row["id"] > cutoff:
                recent = (recent + [row])[-5:]
                if review_active:
                    recovery = (recovery + [row])[-3:]
                    if (len(recovery) == 3 and all(r["ease"] != 1 for r in recovery)
                            and sum(r["ease"] in (3, 4) for r in recovery) >= 2):
                        review_active, recent, recovery = False, [], []
                elif len(recent) >= 3 and _trigger(recent):
                    review_active, recovery = True, []
        elif valid and row["type"] in (0, 2) and row["id"] > cutoff:
            learning_rows.append(row)
            if _trigger(learning_rows, learning=True):
                learning_evidence = _evidence("learning", learning_rows)
        previous = row
    signals = [_evidence("review", recent)] if review_active else []
    # Positive daily intervals do not prove graduation: consult native card.type.
    if card_type in (1, 3) and learning_evidence is not None:
        signals.append(learning_evidence)
    return signals


def _row_hash(row: dict) -> str:
    return hashlib.sha256(json.dumps(row, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:12]


def custom_data(value: str) -> dict:
    try:
        data = json.loads(value or "{}")
    except (TypeError, ValueError) as error:
        raise DifficultyError("invalid-custom-data") from error
    if not isinstance(data, dict):
        raise DifficultyError("invalid-custom-data")
    return data


def baseline(data: dict, rows: list[dict]) -> int:
    marker = data.get(BASELINE_KEY)
    if marker is None:
        return 0
    if (not isinstance(marker, list) or len(marker) != 3 or type(marker[0]) is not int
            or marker[0] != SCHEMA_VERSION or type(marker[1]) is not int or marker[1] < 0
            or not isinstance(marker[2], str)):
        raise DifficultyError("invalid-reassessment-anchor")
    if marker[1] == 0 and marker[2] == "":
        return 0
    anchor = next((row for row in rows if row["id"] == marker[1]), None)
    if anchor is None or _row_hash(anchor) != marker[2]:
        raise DifficultyError("reassessment-anchor-changed")
    return marker[1]


def reassessed_data(value: str, rows: list[dict]) -> str:
    data = custom_data(value)
    baseline(data, rows)  # Refuse unknown/corrupt versions instead of discarding them.
    last = max(rows, key=lambda r: r["id"]) if rows else None
    data[BASELINE_KEY] = [SCHEMA_VERSION, last["id"] if last else 0, _row_hash(last) if last else ""]
    result = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    if len(result.encode("utf-8")) > 100 or any(len(key.encode("utf-8")) > 8 for key in data):
        raise DifficultyError("custom-data-capacity-exceeded")
    return result


def review_rows(col, card_id: int) -> list[dict]:
    columns = ("id", "ease", "type", "ivl", "lastIvl", "factor", "time")
    return [dict(zip(columns, row, strict=True)) for row in col.db.all(
        "select id, ease, type, ivl, lastIvl, factor, time from revlog where cid=? order by id", card_id)]


def card_payload(col, card_id: int, *, now: int) -> dict:
    card = col.get_card(card_id)
    if card.note().note_type()["name"] != MODEL_NAME:
        raise DifficultyError("unmanaged-difficulty-card")
    rows = review_rows(col, card_id)
    cutoff = baseline(custom_data(card.custom_data), rows)
    rollover = col.get_preferences().scheduling.rollover
    return {"schema_version": SCHEMA_VERSION, "card_id": str(card.id), "generated_at": now,
            "source": "local", "signals": assess(rows, card_type=card.type, cutoff=cutoff,
                                                    day=lambda ms: study_day(ms, rollover))}


def reassess_card(col, card_id: int) -> None:
    card = col.get_card(card_id)
    if card.note().note_type()["name"] != MODEL_NAME:
        raise DifficultyError("unmanaged-difficulty-card")
    rows = review_rows(col, card_id)
    if "dce" in custom_data(card.custom_data):
        from . import difficulty_mobile
        card.custom_data = difficulty_mobile.card_data(card, rows, reassess=True)
    else:
        card.custom_data = reassessed_data(card.custom_data, rows)
    col.update_card(card)


def script_payload(payload: dict) -> str:
    """Safe script literal: user data cannot terminate the inline script."""
    return json.dumps(payload, ensure_ascii=True, separators=(",", ":")).replace("<", "\\u003c").replace(
        ">", "\\u003e").replace("&", "\\u0026")
