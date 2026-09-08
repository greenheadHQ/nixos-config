"""응답 축소 — 카드 본문은 길고(HTML·KaTeX) 토큰 예산은 작다. 필드 절단과 페이지네이션은 여기 순수 함수로 두고 테스트한다."""

from __future__ import annotations

from typing import Any


def truncate(value: str, max_chars: int) -> str:
    """max_chars <= 0 이면 절단하지 않는다. 절단 시 원 길이를 표시해 호출자가 전체를 다시 요청할 수 있게 한다."""
    if max_chars <= 0 or len(value) <= max_chars:
        return value
    return f"{value[:max_chars]}…[truncated {max_chars}/{len(value)} chars]"


def page(items: list[Any], limit: int, offset: int, page_max: int) -> tuple[list[Any], dict[str, Any]]:
    """offset/limit 페이지네이션. limit은 1..page_max로 고정한다. meta에 다음 offset(없으면 None)을 싣는다."""
    limit = max(1, min(limit, page_max))
    offset = max(0, offset)
    total = len(items)
    chunk = items[offset : offset + limit]
    next_offset = offset + limit if offset + limit < total else None
    return chunk, {"total": total, "offset": offset, "limit": limit, "next_offset": next_offset}


def note_view(note: dict[str, Any], max_chars: int) -> dict[str, Any]:
    """notesInfo 항목 → {noteId, modelName, tags, fields{name: value}, cards}. 필드 순서는 Anki의 order를 따른다."""
    fields = note.get("fields") or {}
    ordered = sorted(fields.items(), key=lambda kv: kv[1].get("order", 0))
    return {
        "noteId": note.get("noteId"),
        "modelName": note.get("modelName"),
        "tags": note.get("tags") or [],
        "fields": {name: truncate(str(spec.get("value", "")), max_chars) for name, spec in ordered},
        "cards": note.get("cards") or [],
    }


def card_view(card: dict[str, Any], max_chars: int) -> dict[str, Any]:
    """cardsInfo 항목 → 학습 상태 위주. 렌더된 question/answer는 절단하고 css는 뺀다."""
    return {
        "cardId": card.get("cardId"),
        "noteId": card.get("note"),
        "deckName": card.get("deckName"),
        "modelName": card.get("modelName"),
        "ord": card.get("ord"),
        "queue": card.get("queue"),
        "type": card.get("type"),
        "due": card.get("due"),
        "interval": card.get("interval"),
        "factor": card.get("factor"),
        "reps": card.get("reps"),
        "lapses": card.get("lapses"),
        "question": truncate(str(card.get("question", "")), max_chars),
        "answer": truncate(str(card.get("answer", "")), max_chars),
    }
