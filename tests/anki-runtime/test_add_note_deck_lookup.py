"""Exact, fresh deck lookups using the pinned Anki collection backend."""
import unicodedata

import pytest

from test_real_collection import runtime  # noqa: F401


def spec(names, model='Basic'):
    return {'action': 'add_notes', 'params': {'notes': [
        {'deck_name': name, 'model_name': model,
         'fields': {'Text': '{{c1::x}}'} if model == 'Cloze' else {'Front': 'x', 'Back': 'y'},
         'tags': []} for name in names], 'allow_duplicate': True}}


@pytest.mark.parametrize('alias', ['exact', ' Exact ', 'Exact::', 'Exact\x1f', unicodedata.normalize('NFD', '한글')])
def test_add_notes_keeps_exact_names_and_never_creates_aliases(runtime, alias):
    r = runtime
    for name in ('Exact', '한글'):
        r.col.decks.id(name)
    before = r.ac.deckNames()
    with pytest.raises(r.error, match='^deck-not-found$'):
        r.adapter.inspect(spec([alias]))
    assert r.ac.deckNames() == before
    actual = r.adapter.inspect(spec(['Exact', '한글', 'Exact']))
    assert sorted(actual['snapshot']['decks']) == ['Exact', '한글']
    assert actual['summary']['cards'] == 3


@pytest.mark.parametrize('change', ['modify', 'delete', 'rename', 'create'])
def test_cloze_hook_changes_are_seen_by_next_note(runtime, change):
    from anki import hooks
    r = runtime
    if change != 'create':
        r.col.decks.id('Target')
    calls = []
    def change_deck(_note):
        calls.append(True)
        if len(calls) != 1:
            return
        if change == 'create':
            r.col.decks.id('Target')
        elif change == 'delete':
            r.ac.deleteDecks(decks=['Target'], cardsToo=True)
        else:
            deck = r.col.decks.by_name('Target')
            deck['desc' if change == 'modify' else 'name'] = 'changed'
            r.col.decks.save(deck)
    hooks.note_will_flush.append(change_deck)
    try:
        request = spec(['Target' if change == 'modify' else 'Default', 'Target'], 'Cloze')
        if change in ('delete', 'rename'):
            with pytest.raises(r.error, match='^deck-not-found$'):
                r.adapter.inspect(request)
        else:
            result = r.adapter.inspect(request)
            assert result['summary']['cards'] == 2
            if change == 'modify':
                assert result['snapshot']['decks']['Target']['desc'] == 'changed'
    finally:
        hooks.note_will_flush.remove(change_deck)
    assert r.col.note_count() == 0


def test_add_notes_rechecks_target_after_export_reopens_collection(runtime):
    r = runtime
    r.col.decks.id('Target')
    request = spec(['Target'] * 21)
    preview = r.ops.prepare(request['action'], request['params'])
    original_restore = r.ops.restore
    def restore(operation_id):
        result = original_restore(operation_id)
        deck = r.col.decks.by_name('Target')
        deck['desc'] = 'changed during backup'
        r.col.decks.save(deck)
        return result
    r.ops.restore = restore
    with pytest.raises(r.error, match='stale-preview'):
        r.ops.apply(preview['operation_id'], preview['preview_token'], True)
    assert r.col.note_count() == 0
