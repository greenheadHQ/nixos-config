"""Native deletion retains revlog; generated collections, no accounts or SQL writes."""

import pytest
from anki.consts import REM_CARD, REM_DECK, REM_NOTE

from test_deck_delete_receipts import filtered_deck_with_card
from test_real_collection import add, runtime  # noqa: F401


@pytest.mark.parametrize('action', ['delete_notes', 'delete_decks'])
def test_deletion_tombstones_keep_history_and_total_today_rows(runtime, action):
    r = runtime
    for name in ('Target', 'Target::Child', 'Keep'):
        r.apply('create_deck', {'name': name})
    nids = [add(r, 'Basic (and reversed card)', deck='Target'),
            add(r, fields={'Front': 'child', 'Back': 'answer'}, deck='Target::Child')]
    cids = sorted(cid for nid in nids for cid in r.col.get_note(nid).card_ids())
    keep_nid = add(r, fields={'Front': 'keep', 'Back': 'answer'}, deck='Keep')
    keep_cid = r.col.get_note(keep_nid).card_ids()[0]
    dids = [r.col.decks.by_name(name)['id'] for name in ('Target', 'Target::Child')]
    # The real API creates manual scheduling logs. They count in today_reviews
    # too; avoid inserting fabricated revlog rows or pretending these are answers.
    r.apply('set_due_date', {'card_ids': [*cids, keep_cid], 'days': '2'})
    reviews = r.col.db.all('select * from revlog order by id')
    related_reviews = r.adapter._rows('revlog', 'cid', cids)
    assert len(related_reviews) == len(cids) == 3
    assert len(reviews) == 4
    keep_card = r.col.db.all('select * from cards where id=?', keep_cid)
    graves_before = {tuple(row) for row in r.col.db.all('select oid, type from graves')}
    snapshot_before = r.helper._snapshot()
    assert snapshot_before['today_reviews'] == 4
    assert r.ac.getNumCardsReviewedToday() == 4
    assert snapshot_before['today_reviews_by_deck'] == {'Target': 2, 'Target::Child': 1, 'Keep': 1}

    params = {'note_ids': nids} if action == 'delete_notes' else {'deck_names': ['Target']}
    preview, outcome = r.apply(action, params)

    assert preview['confirmation_required'] is True and preview['backup_required'] is True
    assert preview['summary']['affected_review_rows'] == 3  # Scope, not deleted rows.
    assert outcome['result']['retained_review_rows'] == 3
    assert r.col.db.all('select * from revlog order by id') == reviews
    assert r.col.db.list('select id from notes') == [keep_nid]
    assert r.col.db.list('select id from cards') == [keep_cid]
    assert r.col.db.all('select * from cards where id=?', keep_cid) == keep_card
    # Check native sync tombstones, including both sibling cards of a note.
    graves_after = {tuple(row) for row in r.col.db.all('select oid, type from graves')}
    expected = {(nid, REM_NOTE) for nid in nids} | {(cid, REM_CARD) for cid in cids}
    if action == 'delete_decks':
        expected |= {(did, REM_DECK) for did in dids}
        assert r.col.decks.by_name('Target') is None
        assert r.col.decks.by_name('Target::Child') is None
    else:
        assert [r.col.decks.by_name(name)['id'] for name in ('Target', 'Target::Child')] == dids
    assert graves_after - graves_before == expected
    snapshot_after = r.helper._snapshot()
    assert snapshot_after['revlog'] == snapshot_before['revlog'] == 4
    assert snapshot_after['today_reviews'] == snapshot_before['today_reviews'] == 4
    assert r.ac.getNumCardsReviewedToday() == 4
    assert snapshot_after['today_reviews_by_deck'] == {'Keep': 1}
    assert r.col.db.scalar('select count() from revlog r left join cards c on c.id=r.cid where c.id is null') == 3


@pytest.mark.parametrize('action', ['delete_notes', 'delete_decks'])
def test_deletion_without_reviews_reports_measured_zero(runtime, action):
    r = runtime
    r.apply('create_deck', {'name': 'Target'})
    nid = add(r, deck='Target')
    params = {'note_ids': [nid]} if action == 'delete_notes' else {'deck_names': ['Target']}
    preview, outcome = r.apply(action, params)
    assert preview['summary']['affected_review_rows'] == 0
    assert outcome['result']['retained_review_rows'] == 0
    assert r.col.db.scalar('select count() from revlog') == 0
    assert r.helper._snapshot()['today_reviews'] == 0


def test_filtered_deck_deletion_keeps_card_and_its_history(runtime):
    r = runtime
    r.apply('create_deck', {'name': 'Source'})
    nid = add(r, deck='Source')
    cid = r.col.get_note(nid).card_ids()[0]
    r.apply('set_due_date', {'card_ids': [cid], 'days': '2'})
    reviews = r.col.db.all('select * from revlog order by id')
    assert len(reviews) == 1
    filtered_did = filtered_deck_with_card(r, 'Filtered', cid)
    assert r.helper._snapshot()['today_reviews_by_deck'] == {'Filtered': 1}

    preview, outcome = r.apply('delete_decks', {'deck_names': ['Filtered']})

    assert preview['summary']['affected_review_rows'] == 1
    assert outcome['result']['deleted_cards'] == 0
    assert outcome['result']['retained_review_rows'] == 1
    assert r.col.db.all('select * from revlog order by id') == reviews
    assert r.col.get_note(nid).card_ids() == [cid]
    assert (filtered_did, REM_DECK) in {tuple(row) for row in r.col.db.all('select oid, type from graves')}
    assert r.helper._snapshot()['today_reviews'] == 1
    assert r.helper._snapshot()['today_reviews_by_deck'] == {'Source': 1}
