"""Render inspection candidates from the desktop collection's review history.

The managed template owns the UI. This add-on only supplies a fresh payload
before each reviewer question/answer; it never changes cards or scheduling.
"""

import logging
import time

from aqt import gui_hooks

from . import difficulty


def card_will_show(text, card, kind):
    now = int(time.time() * 1000)
    payload = {"schema_version": difficulty.SCHEMA_VERSION,
               "card_id": str(card.id), "generated_at": now,
               "source": "local", "signals": []}
    if kind in {"reviewQuestion", "reviewAnswer"}:
        try:
            if card.note().note_type()["name"] == difficulty.MODEL_NAME:
                payload = difficulty.card_payload(card.col, card.id, now=now)
        except Exception as error:
            # Never leave another card's payload behind or interrupt studying.
            # Exception text may include private card/collection data.
            logging.getLogger(__name__).warning(
                "Difficulty badge unavailable (%s)", type(error).__name__)
    return "<script>window.AnkiDifficultyCurrent=" + difficulty.script_payload(payload) + ";</script>" + text


gui_hooks.card_will_show.append(card_will_show)
