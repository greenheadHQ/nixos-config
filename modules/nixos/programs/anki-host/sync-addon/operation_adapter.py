"""AnkiConnect's verified in-process API, behind the helper's mutation lock.

Only this adapter touches Anki objects. Inspect again after export: closing and
reopening the collection invalidates the objects obtained before the backup.
"""

from __future__ import annotations

import copy
import hashlib
import re
from typing import Any

from .operations import OperationError, decode_media, filename


# A small, documented subset of the legacy deck-config representation. Preset
# IDs/names and unknown keys cannot be overwritten by a caller-supplied object.
OPTION_RANGES = {
    "new.perDay": (0, 9999),
    "new.order": (0, 1),
    "new.initialFactor": (1300, 9999),
    "rev.perDay": (0, 9999),
    "rev.maxIvl": (1, 36500),
    "rev.ease4": (1.0, 5.0),
    "rev.ivlFct": (0.1, 5.0),
    "rev.hardFactor": (1.0, 5.0),
    "lapse.mult": (0.0, 1.0),
    "lapse.minInt": (1, 36500),
    "lapse.leechFails": (1, 9999),
    "lapse.leechAction": (0, 1),
}
INTEGER_OPTIONS = {"new.perDay", "new.order", "new.initialFactor", "rev.perDay", "rev.maxIvl",
                   "lapse.minInt", "lapse.leechFails", "lapse.leechAction"}


REQUIRED_METHODS = (
    "getDeckConfig", "canAddNotesWithErrorDetail", "addNotes", "updateNoteFields",
    "addTags", "removeTags", "createDeck", "changeDeck", "deleteNotes", "deleteDecks",
    "suspend", "areSuspended", "setDueDate", "forgetCards", "storeMediaFile", "saveDeckConfig",
    "modelFieldAdd", "modelFieldRemove", "modelFieldRename", "modelFieldReposition",
    "modelTemplateAdd", "modelTemplateRemove", "updateModelTemplates", "updateModelStyling",
    "getMediaFilesNames",
)


class AnkiAdapter:
    def __init__(self, window: Any, media_limit: int) -> None:
        self.mw = window
        self.media_limit = media_limit

    @property
    def ac(self) -> Any:
        if getattr(self.mw, "_anki_host_connect_version", None) != 1:
            raise OperationError("anki-connect-bridge-unavailable")
        return self.mw._anki_host_connect

    def check_bridge(self) -> None:
        bridge = self.ac
        if any(not callable(getattr(bridge, method, None)) for method in REQUIRED_METHODS):
            raise OperationError("anki-connect-bridge-incompatible")

    @property
    def col(self) -> Any:
        if self.mw.col is None:
            raise OperationError("collection-not-open")
        return self.mw.col

    def _rows(self, table: str, column: str, values: list[int]) -> list[list[Any]]:
        # Names are caller constants; values always use bound SQL parameters.
        rows = []
        for offset in range(0, len(values), 900):
            chunk = values[offset:offset + 900]
            rows.extend(self.col.db.all(f"select * from {table} where {column} in ({','.join('?' for _ in chunk)})", *chunk))
        return sorted(rows, key=lambda row: row[0])

    def _cards(self, card_ids: list[int]) -> list[Any]:
        cards = []
        for cid in card_ids:
            try:
                cards.append(self.col.get_card(cid))
            except Exception as err:
                raise OperationError("card-not-found") from err
        return cards

    def _notes(self, note_ids: list[int]) -> list[Any]:
        notes = []
        for nid in note_ids:
            try:
                notes.append(self.col.get_note(nid))
            except Exception as err:
                raise OperationError("note-not-found") from err
        return notes

    def _model(self, name: str) -> dict[str, Any]:
        model = self.col.models.by_name(name)
        if model is None:
            raise OperationError("note-type-not-found")
        return copy.deepcopy(model)

    def _decks(self) -> dict[str, dict[str, Any]]:
        return {deck["name"]: copy.deepcopy(deck) for deck in self.col.decks.all()}

    def _deck(self, name: str) -> dict[str, Any]:
        deck = self._decks().get(name)
        if deck is None:
            raise OperationError("deck-not-found")
        return deck

    def deck_options(self, name: str) -> dict[str, Any]:
        deck = self._deck(name)
        if deck.get("dyn"):
            raise OperationError("filtered-deck-has-no-standard-preset")
        config = self.ac.getDeckConfig(deck=name)
        if not isinstance(config, dict):
            raise OperationError("deck-config-unavailable")
        shared = sorted(d["name"] for d in self._decks().values()
                        if not d.get("dyn") and str(d.get("conf")) == str(config["id"]))
        editable = {}
        for key in OPTION_RANGES:
            group, field = key.split(".")
            if group in config and field in config[group]:
                editable[key] = config[group][field]
        return {"deck": name, "preset_id": config["id"], "preset_name": config.get("name"),
                "shared_decks": shared, "options": editable, "config": config}

    def model_info(self, name: str) -> dict[str, Any]:
        model = self._model(name)
        return {"name": name, "id": model["id"], "type": model["type"],
                "fields": [{"name": f["name"], "index": f["ord"]} for f in model["flds"]],
                "templates": [{"name": t["name"], "index": t["ord"], "front": t["qfmt"], "back": t["afmt"]}
                              for t in model["tmpls"]], "css": model["css"]}

    def _model_check(self, action: str, p: dict[str, Any], model: dict[str, Any]) -> None:
        collection = model["flds"] if "_field_" in action else model["tmpls"]
        name = p.get("field_name", p.get("template_name"))
        names = [item["name"] for item in collection]
        if action.endswith("_add"):
            if name in names:
                raise OperationError("name-already-exists")
        elif name is not None and name not in names:
            raise OperationError("model-member-not-found")
        if action.endswith("_remove") and len(collection) <= 1:
            raise OperationError("cannot-remove-last-field-or-template")
        if action.endswith("_rename") and p["new_name"] in names:
            raise OperationError("name-already-exists")
        if "index" in p:
            upper = len(collection) if action.endswith("_add") else len(collection) - 1
            if p["index"] > upper:
                raise OperationError("index-out-of-range")
        if "_template_" in action and model["type"] == 1 and action != "model_template_update":
            raise OperationError("cloze-note-types-have-one-template")

    def _config_patch(self, config: dict[str, Any], changes: dict[str, Any]) -> dict[str, Any]:
        config = copy.deepcopy(config)
        for key, value in changes.items():
            if key not in OPTION_RANGES or type(value) not in (int, float):
                raise OperationError("unsupported-deck-option")
            low, high = OPTION_RANGES[key]
            if not low <= value <= high or (key in INTEGER_OPTIONS and type(value) is not int):
                raise OperationError("deck-option-out-of-range")
            group, field = key.split(".")
            if group not in config or field not in config[group]:
                raise OperationError("deck-option-not-supported-by-this-version")
            config[group][field] = value
        return config

    def _media_hash(self, name: str) -> str | None:
        # Never load an arbitrary large existing file just to compare it.
        path = self.col.media.dir()
        from pathlib import Path
        import os
        import stat
        target = Path(path) / filename(name)
        try:
            fd = os.open(target, os.O_RDONLY | os.O_NOFOLLOW)
        except FileNotFoundError:
            return None
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode) or st.st_size > self.media_limit:
                raise OperationError("existing-media-is-not-a-small-regular-file")
            with os.fdopen(fd, "rb", closefd=False) as stream:
                return hashlib.sha256(stream.read(self.media_limit + 1)).hexdigest()
        finally:
            os.close(fd)

    @staticmethod
    def _anticipated_ordinals(model: dict[str, Any], values: dict[str, str]) -> set[int]:
        if model["type"] == 1:
            return {int(n) - 1 for n in re.findall(r"\{\{c([1-9][0-9]*)::", " ".join(values.values()))}
        # Include every template, even when conditions currently hide its card.
        return set(range(len(model["tmpls"])))

    def inspect(self, spec: dict[str, Any]) -> dict[str, Any]:
        action, p = spec["action"], spec["params"]
        note_ids, card_ids = list(p.get("note_ids", [])), list(p.get("card_ids", []))
        if "note_id" in p:
            note_ids = [p["note_id"]]
        snapshot: dict[str, Any] = {}
        warnings: list[str] = []
        summary: dict[str, Any] = {"notes": 0, "cards": 0, "new_notes": 0, "warnings": warnings}
        if action == "add_notes":
            models, decks = {}, {}
            anticipated_cards = 0
            for n in p["notes"]:
                model = self._model(n["model_name"])
                deck = self._deck(n["deck_name"])
                if deck.get("dyn"):
                    raise OperationError("cannot-add-notes-to-filtered-deck")
                if set(n["fields"]) - {f["name"] for f in model["flds"]}:
                    raise OperationError("unknown-note-field")
                models[n["model_name"]] = model
                decks[n["deck_name"]] = deck
                anticipated_cards += max(1, len(self._anticipated_ordinals(model, n["fields"])))
            snapshot.update(models=models, decks=decks)
            summary.update(new_notes=len(p["notes"]), cards=anticipated_cards,
                           decks=sorted(decks), anticipated_cards=True)
        elif action == "create_deck":
            # Include ancestors: createDeck may create them too.
            ancestors = ["::".join(p["name"].split("::")[:i]) for i in range(1, len(p["name"].split("::")) + 1)]
            if any(not part.strip() for part in p["name"].split("::")):
                raise OperationError("invalid-deck-name")
            existing = self._decks()
            snapshot["decks"] = {n: existing.get(n) for n in ancestors}
            summary["decks"] = ancestors
        elif action == "delete_decks":
            all_decks = self._decks()
            if set(p["deck_names"]) - all_decks.keys():
                raise OperationError("deck-not-found")
            affected = {name: d for name, d in all_decks.items()
                        if any(name == root or name.startswith(root + "::") for root in p["deck_names"])}
            dids = sorted(d["id"] for d in affected.values())
            cards = {row[0]: row for row in self._rows("cards", "did", dids) + self._rows("cards", "odid", dids)}
            card_ids = sorted(cards)
            snapshot["decks"] = affected
            ordinary_dids = {int(d["id"]) for d in affected.values() if not d.get("dyn")}
            removing = {c.id for c in self._cards(card_ids) if c.did in ordinary_dids or c.odid in ordinary_dids}
            affected_nids = sorted({c.nid for c in self._cards(card_ids)})
            membership = [[row[0], row[1]] for row in self._rows("cards", "nid", affected_nids)]
            snapshot["note_card_membership"] = membership
            summary["cards_to_remove"] = len(removing)
            summary["notes_to_remove"] = sum(all(cid in removing for cid, note_id in membership if note_id == nid)
                                              for nid in affected_nids)
            summary["decks"] = sorted(affected)
            if any(d.get("dyn") for d in affected.values()):
                warnings.append("Filtered decks return cards to their original decks; deleting an original deck can delete those cards.")
            if any(int(d["id"]) == 1 for d in affected.values()):
                warnings.append("The Default deck itself remains, but its cards can be deleted.")
            warnings.append("Subdecks and their affected cards are included.")
        elif action == "move_cards":
            deck = self._deck(p["deck_name"])
            if deck.get("dyn"):
                raise OperationError("cannot-move-cards-into-filtered-deck")
            snapshot["target_deck"] = deck
            summary["decks"] = [p["deck_name"]]
            warnings.append("Cards in filtered decks first return to their original scheduling state.")
        elif action == "update_deck_options":
            options = self.deck_options(p["deck_name"])
            self._config_patch(options["config"], p["changes"])
            snapshot["options"] = options
            shared = options["shared_decks"]
            dids = sorted(self._deck(n)["id"] for n in shared)
            card_ids = sorted({row[0] for row in self._rows("cards", "did", dids) + self._rows("cards", "odid", dids)})
            summary.update(preset_id=options["preset_id"], shared_decks=shared, shared_preset=len(shared) > 1,
                           changes=p["changes"])
            if len(shared) > 1:
                warnings.append("This preset is shared; the change affects every listed deck.")
        elif action.startswith("model_"):
            model = self._model(p["model_name"])
            self._model_check(action, p, model)
            snapshot["model"] = model
            note_ids = sorted(self.col.db.list("select id from notes where mid=?", model["id"]))
            summary["model"] = p["model_name"]
            if action != "model_css_update":
                warnings.append("Note-type changes may require a full sync. Only the root approval command can apply this operation.")
            if action == "model_field_remove":
                warnings.append("The selected field's contents will be removed from every affected note.")
            if action == "model_template_remove":
                ordinal = next(t["ord"] for t in model["tmpls"] if t["name"] == p["template_name"])
                summary["cards_to_remove"] = self.col.db.scalar(
                    "select count() from cards c join notes n on n.id=c.nid where n.mid=? and c.ord=?", model["id"], ordinal)
        elif action == "store_media":
            data_hash = hashlib.sha256(decode_media(p["data"], self.media_limit)).hexdigest()
            existing_hash = self._media_hash(p["filename"])
            if existing_hash is not None and existing_hash != data_hash:
                raise OperationError("media-exists-with-different-content")
            snapshot["media"] = {"filename": p["filename"], "hash": existing_hash}
            summary.update(filename=p["filename"], bytes=len(decode_media(p["data"], self.media_limit)),
                           unchanged=existing_hash == data_hash)
        if note_ids:
            notes = self._notes(note_ids)
            card_ids = sorted(set(card_ids) | {cid for n in notes for cid in n.card_ids()})
            if action == "update_fields":
                if set(p["fields"]) - set(notes[0].keys()):
                    raise OperationError("unknown-note-field")
                model = copy.deepcopy(notes[0].note_type())
                snapshot["model"] = model
                changed_fields = {**dict(notes[0].items()), **p["fields"]}
                # Old cloze cards remain until the user removes empty cards; a
                # disjoint new set of cloze ordinals is additive, not a swap.
                ordinals = {c.ord for c in self._cards(card_ids)} | self._anticipated_ordinals(model, changed_fields)
                summary["cards"] = max(len(card_ids), len(ordinals))
                summary["anticipated_cards"] = True
                warnings.append("Updating fields may activate templates or cloze deletions and generate new cards.")
        if card_ids:
            cards = self._cards(card_ids)
            note_ids = sorted(set(note_ids) | {c.nid for c in cards})
            snapshot["cards"] = self._rows("cards", "id", card_ids)
            snapshot["reviews"] = self._rows("revlog", "cid", card_ids)
        if note_ids:
            snapshot["notes"] = self._rows("notes", "id", note_ids)
        summary["notes"] = len(note_ids)
        summary["cards"] = max(len(card_ids), summary["cards"])
        summary["note_ids"] = note_ids[:100]
        summary["card_ids"] = card_ids[:100]
        summary["ids_truncated"] = len(note_ids) > 100 or len(card_ids) > 100
        if action in ("delete_notes", "delete_decks"):
            summary["affected_review_rows"] = len(snapshot.get("reviews", []))
            warnings.append("Deletion may remove cards and their review history; a verified restore point is required.")
        if action == "set_due_date":
            warnings.append("Ranges choose a random day; scheduling changes can add manual review-log entries and unsuspend cards.")
        if action == "forget_cards":
            warnings.append("Reset to new-card scheduling; existing review history is retained and a manual log entry may be added.")
        return {"snapshot": snapshot, "summary": summary}

    def _add_notes(self, p: dict[str, Any]) -> dict[str, Any]:
        notes = [{"deckName": n["deck_name"], "modelName": n["model_name"], "fields": n["fields"],
                  "tags": n["tags"], "options": {"allowDuplicate": p["allow_duplicate"], "duplicateScope": "deck"}}
                 for n in p["notes"]]
        checks = self.ac.canAddNotesWithErrorDetail(notes=notes)
        if not isinstance(checks, list) or len(checks) != len(notes):
            raise OperationError("invalid-addability-result")
        results = []
        # Execute one input at a time: every confirmed ID reaches the caller even
        # if a later item fails. The outer journal still guards the whole request.
        for note, check in zip(notes, checks, strict=True):
            if not isinstance(check, dict) or check.get("canAdd") is not True:
                results.append({"noteId": None, "error": "note-not-addable"})
                continue
            try:
                returned = self.ac.addNotes(notes=[note])
                if not isinstance(returned, list) or len(returned) != 1 or type(returned[0]) is not int or returned[0] <= 0:
                    results.append({"noteId": None, "error": "add-result-unknown"})
                else:
                    results.append({"noteId": returned[0], "error": None})
            except Exception:
                results.append({"noteId": None, "error": "add-result-unknown"})
        added = sum(r["noteId"] is not None for r in results)
        return {"state": "applied" if added == len(notes) else "partial", "added": added,
                "results": results, "tag": "mcp::added"}

    def apply(self, spec: dict[str, Any]) -> dict[str, Any]:
        action, p = spec["action"], spec["params"]
        ac = self.ac
        result: dict[str, Any] = {"state": "applied"}
        if action == "add_notes":
            result = self._add_notes(p)
        elif action == "update_fields":
            ac.updateNoteFields(note={"id": p["note_id"], "fields": p["fields"]})
            result["note_id"] = p["note_id"]
        elif action == "add_tags":
            ac.addTags(notes=p["note_ids"], tags=" ".join(p["tags"]))
        elif action == "remove_tags":
            ac.removeTags(notes=p["note_ids"], tags=" ".join(p["tags"]))
        elif action == "create_deck":
            result["deck_id"] = ac.createDeck(deck=p["name"])
        elif action == "move_cards":
            ac.changeDeck(cards=p["card_ids"], deck=p["deck_name"])
        elif action == "delete_notes":
            ac.deleteNotes(notes=p["note_ids"])
        elif action == "delete_decks":
            # Passing only topmost selected roots avoids removing a subdeck twice.
            roots = [n for n in p["deck_names"] if not any(n.startswith(parent + "::") for parent in p["deck_names"] if parent != n)]
            ac.deleteDecks(decks=roots, cardsToo=True)
        elif action == "suspend_cards":
            ac.suspend(cards=list(p["card_ids"]), suspend=p["suspended"])
            states = ac.areSuspended(cards=p["card_ids"])
            if states != [p["suspended"]] * len(p["card_ids"]):
                raise OperationError("suspension-readback-mismatch")
        elif action == "set_due_date":
            if ac.setDueDate(cards=p["card_ids"], days=p["days"]) is not True:
                raise OperationError("schedule-update-failed")
        elif action == "forget_cards":
            ac.forgetCards(cards=p["card_ids"])
        elif action == "store_media":
            expected = hashlib.sha256(decode_media(p["data"], self.media_limit)).hexdigest()
            if self._media_hash(p["filename"]) != expected:
                stored = ac.storeMediaFile(filename=p["filename"], data=p["data"], deleteExisting=False)
                if stored != p["filename"] or self._media_hash(p["filename"]) != expected:
                    raise OperationError("media-readback-mismatch")
            result.update(filename=p["filename"], sha256=expected)
        elif action == "update_deck_options":
            options = self.deck_options(p["deck_name"])
            config = self._config_patch(options["config"], p["changes"])
            if ac.saveDeckConfig(config=config) is not True:
                raise OperationError("deck-options-save-failed")
            after = self.deck_options(p["deck_name"])
            if any(after["options"].get(k) != v for k, v in p["changes"].items()):
                raise OperationError("deck-options-readback-mismatch")
            result.update(preset_id=after["preset_id"], shared_decks=after["shared_decks"])
        elif action == "model_field_add":
            ac.modelFieldAdd(modelName=p["model_name"], fieldName=p["field_name"], index=p.get("index"))
        elif action == "model_field_remove":
            ac.modelFieldRemove(modelName=p["model_name"], fieldName=p["field_name"])
        elif action == "model_field_rename":
            ac.modelFieldRename(modelName=p["model_name"], oldFieldName=p["field_name"], newFieldName=p["new_name"])
        elif action == "model_field_reposition":
            ac.modelFieldReposition(modelName=p["model_name"], fieldName=p["field_name"], index=p["index"])
        elif action == "model_template_add":
            ac.modelTemplateAdd(modelName=p["model_name"], template={"Name": p["template_name"], "Front": p["front"], "Back": p["back"]})
        elif action == "model_template_remove":
            ac.modelTemplateRemove(modelName=p["model_name"], templateName=p["template_name"])
        elif action == "model_template_update":
            ac.updateModelTemplates(model={"name": p["model_name"], "templates": {
                p["template_name"]: {"Front": p["front"], "Back": p["back"]}}})
        elif action == "model_css_update":
            ac.updateModelStyling(model={"name": p["model_name"], "css": p["css"]})
        else:
            raise OperationError("unsupported-operation")
        self.mw.reset()
        return result
