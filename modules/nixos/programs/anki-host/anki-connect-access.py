"""Installed next to AnkiConnect by the host's small addon derivation patch."""

import hmac
import os
from pathlib import Path

READ_ACTIONS = frozenset({
    "version", "getActiveProfile", "getNumCardsReviewedToday", "deckNames", "deckNamesAndIds", "getDeckStats",
    "modelNames", "modelFieldNames", "modelTemplates", "modelStyling", "findNotes", "notesInfo", "findCards",
    "cardsInfo", "getReviewsOfCards", "getTags", "areSuspended", "getDeckConfig",
})


def load_key():
    path = os.path.join(os.environ["CREDENTIALS_DIRECTORY"], "read")
    value = Path(path).read_text(encoding="ascii").strip()
    if len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
        raise RuntimeError("anki-host read credential is missing or invalid")
    return value


READ_KEY = load_key()  # Fail before binding the HTTP listener.


def check_request(request, ac):
    if not isinstance(request, dict) or request.get("version") != 6:
        raise Exception("AnkiConnect API version 6 is required")
    key = request.get("key")
    if (not isinstance(key, str) or len(key) != 64 or any(c not in "0123456789abcdef" for c in key)
            or not hmac.compare_digest(key, READ_KEY)):
        raise Exception("valid api key must be provided")
    action, params = request.get("action"), request.get("params", {})
    if action not in READ_ACTIONS or not isinstance(params, dict):
        raise Exception("action is not available on the read-only AnkiConnect endpoint")
    if action == "getDeckStats":
        names = params.get("decks")
        # Upstream getDeckStats calls decks.id(), which creates unknown decks.
        if not isinstance(names, list) or any(not isinstance(n, str) or n not in ac.deckNames() for n in names):
            raise Exception("deck not found")
