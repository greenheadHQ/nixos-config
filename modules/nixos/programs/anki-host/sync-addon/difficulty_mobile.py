"""Opt-in mobile event summaries; the review log remains the source of truth.

Only an explicit, quiescent-device operator operation installs or reconciles
these summaries. Never write card metadata while rendering or after background
sync: doing so can win a whole-card conflict against another device's answer.
"""
from __future__ import annotations

import json
import math
from pathlib import Path
import re

from . import difficulty

KEY = "dce"
VERSION = 2
CONFIG_KEY = "cardStateCustomizer"
MAX_COUNT = 0xFFFFFFFF
MAX_ID = (1 << 53) - 1
SCRIPT_PATH = Path(__file__).with_name("difficulty-scheduler.js")


def script() -> str:
    return SCRIPT_PATH.read_text(encoding="utf-8")


def _base36(value: int) -> str:
    alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"
    result = ""
    while value:
        value, remainder = divmod(value, 36)
        result = alphabet[remainder] + result
    return result or "0"


def grades(value: int) -> list[int]:
    result = []
    while value:
        value, grade = divmod(value, 5)
        if grade == 0:
            raise difficulty.DifficultyError("invalid-mobile-summary")
        result.insert(0, grade)
    return result


def encode(state: list[int]) -> str:
    return ".".join("-" if n == -1 else _base36(n) for n in state)


def decode(value: object, *, card_id: int | None = None) -> list[int]:
    if not isinstance(value, str) or re.fullmatch(r"2\.[0-9a-z]+\.[0-9a-z]+\.(?:-|[0-9a-z]+)\.[0-9a-z]+\.[0-9a-z]+\.[0-9a-z]+", value) is None:
        raise difficulty.DifficultyError("invalid-mobile-summary")
    state = [-1 if part == "-" else int(part, 36) for part in value.split(".")]
    _, cid, recent, recovery, samples, again, hard = state
    if (encode(state) != value or not 0 < cid <= MAX_ID or card_id is not None and cid != card_id
            or not 0 <= recent < 3125 or not -1 <= recovery < 125
            or not 0 <= again + hard <= samples <= MAX_COUNT):
        raise difficulty.DifficultyError("invalid-mobile-summary")
    grades(recent)
    if recovery >= 0:
        grades(recovery)
    return state


def empty(card_id: int) -> list[int]:
    return [VERSION, card_id, 0, -1, 0, 0, 0]


def advance(state: list[int], kind: int, ease: int, *, graduated: bool = False) -> list[int]:
    """Pure reducer shared by contract with difficulty-scheduler.js.

    kind=1 is a rescheduling Review, 0/2 learning/relearning; other kinds do
    not count. Manual operations clear only the learning episode on replay.
    """
    result = list(state)
    if kind in (1, 4, 5):
        result[4:] = [0, 0, 0]
    if ease in (1, 2, 3, 4) and kind == 1:
        result[2] = (result[2] * 5 + ease) % 3125
        recent = grades(result[2])
        if result[3] >= 0:
            result[3] = (result[3] * 5 + ease) % 125
            recovery = grades(result[3])
            if len(recovery) == 3 and 1 not in recovery and sum(g >= 3 for g in recovery) >= 2:
                result[2:4] = [0, -1]
        elif len(recent) >= 3 and difficulty._trigger([{"ease": g} for g in recent]):
            result[3] = 0
    elif ease in (1, 2, 3, 4) and kind in (0, 2):
        result[4] += 1
        result[5] += ease == 1
        result[6] += ease == 2
    if graduated:
        result[4:] = [0, 0, 0]
    if result[4] > MAX_COUNT:
        raise difficulty.DifficultyError("mobile-summary-capacity-exceeded")
    return result


def replay(card_id: int, rows: list[dict], *, card_type: int, cutoff: int = 0) -> list[int]:
    state = empty(card_id)
    ordered = sorted(rows, key=lambda row: row["id"])
    if len({row["id"] for row in ordered}) != len(ordered):
        raise difficulty.DifficultyError("duplicate-review-id")
    for row in ordered:
        if row["id"] > cutoff:
            if difficulty.learning_boundary(row):
                state[4:] = [0, 0, 0]
            state = advance(state, row["type"], row["ease"])
    if card_type not in (1, 3):
        state[4:] = [0, 0, 0]
    return state


def _json(data: dict) -> str:
    return json.dumps(data, ensure_ascii=False, separators=(",", ":"))


def javascript_safe(value) -> bool:
    if type(value) is int and abs(value) > MAX_ID:
        return False
    if type(value) is float and (not math.isfinite(value) or value.is_integer() and abs(value) > MAX_ID):
        return False
    if isinstance(value, dict):
        return all(javascript_safe(item) for item in value.values())
    if isinstance(value, list):
        return all(javascript_safe(item) for item in value)
    return True


def with_summary(data: dict, state: list[int]) -> str:
    """Reserve growth and a future reassessment anchor without deleting keys."""
    if not javascript_safe(data):
        raise difficulty.DifficultyError("custom-data-integer-not-javascript-safe")
    result = dict(data)
    result[KEY] = encode(state)
    decode(result[KEY])
    reserve = dict(result)
    reserve[KEY] = encode([VERSION, state[1], 3124, 124, MAX_COUNT, MAX_COUNT, MAX_COUNT])
    # revlog IDs are milliseconds, bounded to JavaScript's exact integer range.
    # The existing dcb version/hash contract remains independent of this schema.
    reserve[difficulty.BASELINE_KEY] = [difficulty.SCHEMA_VERSION, MAX_ID, "f" * 12]
    if (len(_json(reserve).encode("utf-8")) > 100 or len(_json(result).encode("utf-8")) > 100
            or any(len(key.encode("utf-8")) > 8 for key in result)):
        raise difficulty.DifficultyError("custom-data-capacity-exceeded")
    return _json(result)


def card_data(card, rows: list[dict], *, reassess: bool = False) -> str:
    data = difficulty.custom_data(card.custom_data)
    if KEY in data:
        decode(data[KEY], card_id=card.id)
    cutoff = difficulty.baseline(data, rows)
    if reassess:
        data = difficulty.custom_data(difficulty.reassessed_data(card.custom_data, rows))
        state = empty(card.id)
    else:
        state = replay(card.id, rows, card_type=card.type, cutoff=cutoff)
    return with_summary(data, state)


def plan(col, *, enabled: bool) -> dict:
    """Preflight the whole target before any mutation, including foreign code."""
    current = col.get_config(CONFIG_KEY, None)
    owned = script()
    if current not in (None, "", "void 0;", owned):
        raise difficulty.DifficultyError("custom-scheduling-already-configured")
    model = col.models.by_name(difficulty.MODEL_NAME)
    if model is None:
        raise difficulty.DifficultyError("managed-difficulty-model-missing")
    card_ids = sorted(col.db.list("select c.id from cards c join notes n on n.id=c.nid where n.mid=?", model["id"]))
    updates = []
    custom_data_snapshot = []
    if enabled:
        # Anki's native custom-scheduling wrapper JSON-parses/stringifies every
        # card, even when this program makes no candidate edits. Check foreign
        # cards too so enabling it cannot round another extension's large IDs.
        for cid in sorted(col.db.list("select id from cards")):
            value = col.get_card(cid).custom_data
            if not javascript_safe(difficulty.custom_data(value)):
                raise difficulty.DifficultyError("custom-data-integer-not-javascript-safe")
            custom_data_snapshot.append((cid, value))
        for cid in card_ids:
            card = col.get_card(cid)
            value = card_data(card, difficulty.review_rows(col, cid))
            if value != card.custom_data:
                updates.append((cid, value))
    return {"before_script": current, "script": owned if enabled else "",
            "card_ids": card_ids, "updates": updates, "custom_data_snapshot": custom_data_snapshot}


def apply(col, prepared: dict) -> None:
    """The operation journal owns backup/CAS; native Undo groups the writes."""
    cards = []
    for cid, value in prepared["updates"]:
        card = col.get_card(cid)
        card.custom_data = value
        cards.append(card)
    entry = col.add_custom_undo_entry("점검 후보 모바일 상태 설정")
    try:
        if cards:
            col.update_cards(cards)
        if prepared["script"] != prepared["before_script"]:
            col.set_config(CONFIG_KEY, prepared["script"], undoable=True)
    finally:
        col.merge_undo_entries(entry)
