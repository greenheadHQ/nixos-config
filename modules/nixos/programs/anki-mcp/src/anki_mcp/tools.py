"""MCP 도구 — plan 030 결정 8(3계층)·9(범용, mcp::added 태그)·10(busy 확인)·13("지금 동기화").

PR 2a 범위: 조회 계층 전부 + 변경 계층 중 추가·수정·태그·덱 생성 + 지금 동기화.
파괴 계층(삭제)·정지·일정·잊기·대량 미리보기·복구점·미디어는 PR 2b.
annotations는 클라이언트(ChatGPT 등)가 위험도에 따라 확인 UX를 결정하는 힌트다.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations
from pydantic import BaseModel, Field

from .ankiconnect import AnkiConnect
from .helper import Helper
from .shaping import card_view, note_view, page, truncate
from .syncstatus import SyncNow, read_status, summarize

ADDED_TAG = "mcp::added"

READ_ONLY = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=False)
ADDITIVE = ToolAnnotations(readOnlyHint=False, destructiveHint=False, idempotentHint=False, openWorldHint=False)
UPDATE = ToolAnnotations(readOnlyHint=False, destructiveHint=False, idempotentHint=True, openWorldHint=False)
SYNC = ToolAnnotations(readOnlyHint=False, destructiveHint=False, idempotentHint=True, openWorldHint=True)


class NewNote(BaseModel):
    deck_name: str = Field(description="Target deck (existing; use anki_create_deck first if needed)")
    model_name: str = Field(description="Note type name, e.g. 'Basic' or 'Cloze' (see anki_models)")
    fields: dict[str, str] = Field(description="Field values by field name; HTML allowed")
    tags: list[str] = Field(default_factory=list, description="Tags to add; 'mcp::added' is always appended")


@dataclass
class Deps:
    anki: AnkiConnect
    helper: Helper
    syncer: SyncNow
    sync_status_file: str
    field_chars: int
    page_max: int


def register_tools(mcp: FastMCP, deps: Deps) -> None:  # noqa: C901 — 도구 정의 나열
    anki = deps.anki

    async def guard_mutation() -> None:
        # 결정 10: 헬퍼의 변경 작업(sync/export/import)과 겹치지 않게 호출 전에 busy를 본다
        await deps.helper.ensure_not_busy()

    @mcp.tool(name="anki_status", annotations=READ_ONLY)
    async def anki_status() -> dict[str, Any]:
        """Host status: helper readiness/login/busy, last sync summary (result vocabulary of the sync script),
        and today's review count. Call this first when something looks off."""
        helper = await deps.helper.status()
        reviewed_today = await anki.invoke("getNumCardsReviewedToday")
        return {
            "helper": {k: helper.get(k) for k in ("collection_open", "login", "busy", "addon_version", "last_sync")},
            "sync": summarize(read_status(deps.sync_status_file)),
            "reviewed_today": reviewed_today,
        }

    @mcp.tool(name="anki_decks", annotations=READ_ONLY)
    async def anki_decks() -> dict[str, Any]:
        """List decks with ids and per-deck counts (new/learn/review due today, total cards)."""
        names: dict[str, int] = await anki.invoke("deckNamesAndIds")
        stats: dict[str, dict[str, Any]] = await anki.invoke("getDeckStats", decks=list(names))
        by_id = {str(v.get("deck_id")): v for v in stats.values()}
        decks = []
        for name, deck_id in sorted(names.items()):
            s = by_id.get(str(deck_id), {})
            decks.append({
                "name": name,
                "id": deck_id,
                "new": s.get("new_count"),
                "learn": s.get("learn_count"),
                "review": s.get("review_count"),
                "total": s.get("total_in_deck"),
            })
        return {"decks": decks}

    @mcp.tool(name="anki_models", annotations=READ_ONLY)
    async def anki_models(name: str | None = None) -> dict[str, Any]:
        """List note types. With `name`, return that type's field names (in order) and card template names."""
        if name is None:
            return {"models": await anki.invoke("modelNames")}
        fields = await anki.invoke("modelFieldNames", modelName=name)
        templates = await anki.invoke("modelTemplates", modelName=name)
        return {"model": name, "fields": fields, "templates": list(templates.keys())}

    @mcp.tool(name="anki_find_notes", annotations=READ_ONLY)
    async def anki_find_notes(
        query: str,
        limit: int = 20,
        offset: int = 0,
        max_field_chars: int = deps.field_chars,
    ) -> dict[str, Any]:
        """Search notes with Anki search syntax passed through verbatim (e.g. 'deck:"CS 재활" tag:mcp::added',
        'added:7', 'is:due', 'front:*css*'). Paginated; field values are truncated to max_field_chars
        (0 = no truncation). Use anki_note_info for full fields of specific notes."""
        ids: list[int] = await anki.invoke("findNotes", query=query)
        chunk, meta = page(ids, limit, offset, deps.page_max)
        notes = await anki.invoke("notesInfo", notes=chunk) if chunk else []
        return {"query": query, "page": meta, "notes": [note_view(n, max_field_chars) for n in notes]}

    @mcp.tool(name="anki_note_info", annotations=READ_ONLY)
    async def anki_note_info(note_ids: list[int], max_field_chars: int = 0) -> dict[str, Any]:
        """Full note details for the given note ids (fields untruncated by default)."""
        chunk, meta = page(note_ids, deps.page_max, 0, deps.page_max)
        notes = await anki.invoke("notesInfo", notes=chunk) if chunk else []
        return {"page": meta, "notes": [note_view(n, max_field_chars) for n in notes]}

    @mcp.tool(name="anki_find_cards", annotations=READ_ONLY)
    async def anki_find_cards(
        query: str,
        limit: int = 20,
        offset: int = 0,
        max_chars: int = deps.field_chars,
    ) -> dict[str, Any]:
        """Search cards (scheduling view: queue/type/due/interval/ease/reps/lapses) with Anki search syntax.
        Rendered question/answer are truncated to max_chars."""
        ids: list[int] = await anki.invoke("findCards", query=query)
        chunk, meta = page(ids, limit, offset, deps.page_max)
        cards = await anki.invoke("cardsInfo", cards=chunk) if chunk else []
        return {"query": query, "page": meta, "cards": [card_view(c, max_chars) for c in cards]}

    @mcp.tool(name="anki_card_reviews", annotations=READ_ONLY)
    async def anki_card_reviews(card_ids: list[int]) -> dict[str, Any]:
        """Review history (revlog) keyed by card id. Each entry: {id: review time (epoch ms), usn, ease: button 1-4,
        ivl: new interval (days; negative = seconds), lastIvl, factor: ease factor (permille), time: ms spent,
        type: 0 learn / 1 review / 2 relearn / 3 filtered / 4 manual}."""
        chunk, meta = page(card_ids, deps.page_max, 0, deps.page_max)
        # AnkiConnect는 revlog.cid를 정수로 비교한다 — 문자열 id를 보내면 빈 결과가 온다
        reviews = await anki.invoke("getReviewsOfCards", cards=chunk) if chunk else {}
        return {"page": meta, "reviews": reviews}

    @mcp.tool(name="anki_tags", annotations=READ_ONLY)
    async def anki_tags() -> dict[str, Any]:
        """All tags in the collection."""
        return {"tags": await anki.invoke("getTags")}

    @mcp.tool(name="anki_add_notes", annotations=ADDITIVE)
    async def anki_add_notes(notes: list[NewNote], allow_duplicate: bool = False) -> dict[str, Any]:
        """Add notes. Every note gets the 'mcp::added' tag so MCP-created cards stay identifiable.
        Duplicates (same first field in the deck) are rejected unless allow_duplicate. Returns ids per note
        (null = failed, see errors). Sync happens automatically within 15 minutes, or call anki_sync_now."""
        await guard_mutation()
        payload = []
        for n in notes:
            tags = list(dict.fromkeys([*n.tags, ADDED_TAG]))
            payload.append({
                "deckName": n.deck_name,
                "modelName": n.model_name,
                "fields": n.fields,
                "tags": tags,
                "options": {"allowDuplicate": allow_duplicate, "duplicateScope": "deck"},
            })
        checks = await anki.invoke("canAddNotesWithErrorDetail", notes=payload)
        addable = [p for p, c in zip(payload, checks) if c.get("canAdd")]
        ids: list[int | None] = await anki.invoke("addNotes", notes=addable) if addable else []
        it = iter(ids)
        result = []
        for c in checks:
            if c.get("canAdd"):
                result.append({"noteId": next(it, None), "error": None})
            else:
                result.append({"noteId": None, "error": c.get("error")})
        return {"added": sum(1 for r in result if r["noteId"]), "results": result, "tag": ADDED_TAG}

    @mcp.tool(name="anki_update_note_fields", annotations=UPDATE)
    async def anki_update_note_fields(note_id: int, fields: dict[str, str]) -> dict[str, Any]:
        """Replace the given fields of a note (other fields unchanged). Card ids, scheduling and review
        history are preserved. Returns the note after the update."""
        await guard_mutation()
        await anki.invoke("updateNoteFields", note={"id": note_id, "fields": fields})
        after = await anki.invoke("notesInfo", notes=[note_id])
        return {"note": note_view(after[0], 0) if after else None}

    @mcp.tool(name="anki_add_tags", annotations=UPDATE)
    async def anki_add_tags(note_ids: list[int], tags: list[str]) -> dict[str, Any]:
        """Add tags to notes (space-separated internally; each tag must not contain spaces)."""
        await guard_mutation()
        await anki.invoke("addTags", notes=note_ids, tags=" ".join(tags))
        return {"notes": len(note_ids), "tags": tags}

    @mcp.tool(name="anki_remove_tags", annotations=UPDATE)
    async def anki_remove_tags(note_ids: list[int], tags: list[str]) -> dict[str, Any]:
        """Remove tags from notes."""
        await guard_mutation()
        await anki.invoke("removeTags", notes=note_ids, tags=" ".join(tags))
        return {"notes": len(note_ids), "tags": tags}

    @mcp.tool(name="anki_create_deck", annotations=ADDITIVE)
    async def anki_create_deck(name: str) -> dict[str, Any]:
        """Create a deck (use '::' for nesting). Existing decks are returned unchanged."""
        await guard_mutation()
        deck_id = await anki.invoke("createDeck", deck=name)
        return {"name": name, "id": deck_id}

    @mcp.tool(name="anki_sync_now", annotations=SYNC)
    async def anki_sync_now() -> dict[str, Any]:
        """Sync the host collection with AnkiWeb now (normal merge only; never a full upload/download).
        Triggers the host's sync service and waits for that run's result. If a run is already in progress the
        request joins it and your latest changes ride the next run."""
        return await deps.syncer.run()

    # 절단 헬퍼를 명시적으로 노출하지는 않지만, 도구 설명이 참조하는 동작이 이 모듈에 있음을 표시
    _ = truncate
