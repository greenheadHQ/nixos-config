"""Deletion receipts checked against real Anki, using generated collections only."""

from test_real_collection import add, runtime  # noqa: F401


def card_ids(r):
    return set(r.col.db.list('select id from cards'))


def assert_receipt(outcome, *, deleted_decks, retained_decks, deleted_cards, retained_cards):
    result = outcome['result']
    assert result['deleted_decks'] == deleted_decks
    assert result['retained_decks'] == retained_decks
    assert type(result['deleted_cards']) is int and result['deleted_cards'] == deleted_cards
    assert type(result['retained_cards']) is int and result['retained_cards'] == retained_cards


def filtered_deck_with_card(r, name, cid):
    """Let Anki move a real card into a filtered deck; do not fake did/odid."""
    did = r.col.decks.new_filtered(name)
    deck = r.col.decks.get(did)
    assert deck['dyn']
    deck['terms'] = [[f'cid:{cid}', 20, 0]]
    deck['resched'] = True
    r.col.decks.save(deck)
    assert r.col.sched.rebuild_filtered_deck(did).count == 1
    assert r.col.get_card(cid).did == did
    return did


def test_delete_ordinary_deck_reports_its_name_and_two_deleted_cards(runtime):
    r = runtime
    r.apply('create_deck', {'name': 'Ordinary'})
    nids = [add(r, fields={'Front': f'ordinary {i}', 'Back': 'answer'}, deck='Ordinary')
            for i in range(2)]
    before = card_ids(r)
    assert len(before) == 2

    _, outcome = r.apply('delete_decks', {'deck_names': ['Ordinary']})

    assert_receipt(outcome, deleted_decks=['Ordinary'], retained_decks=[],
                   deleted_cards=2, retained_cards=0)
    assert r.col.decks.by_name('Ordinary') is None
    assert before - card_ids(r) == before
    assert not card_ids(r)
    assert not r.col.db.list('select id from notes where id in (?, ?)', *nids)


def test_delete_empty_deck_reports_zero_deleted_cards(runtime):
    r = runtime
    r.apply('create_deck', {'name': 'Empty'})

    _, outcome = r.apply('delete_decks', {'deck_names': ['Empty']})

    assert_receipt(outcome, deleted_decks=['Empty'], retained_decks=[],
                   deleted_cards=0, retained_cards=0)
    assert r.col.decks.by_name('Empty') is None
    assert not card_ids(r) and r.col.note_count() == 0


def test_delete_parent_and_duplicate_child_reports_each_deck_once_and_keeps_sibling_card(runtime):
    r = runtime
    for name in ('Parent', 'Parent::Child', 'Keep'):
        r.apply('create_deck', {'name': name})
    add(r, fields={'Front': 'parent card', 'Back': 'answer'}, deck='Parent')
    nid = add(r, 'Basic (and reversed card)', {'Front': 'shared note', 'Back': 'both sides'},
              'Parent::Child')
    siblings = r.col.get_note(nid).card_ids()
    r.apply('move_cards', {'card_ids': [siblings[1]], 'deck_name': 'Keep'})
    untouched = r.col.db.all('select * from cards where id=?', siblings[1])
    before = card_ids(r)

    _, outcome = r.apply('delete_decks', {
        'deck_names': ['Parent::Child', 'Parent', 'Parent::Child'],
    })

    assert_receipt(outcome, deleted_decks=['Parent', 'Parent::Child'], retained_decks=[],
                   deleted_cards=2, retained_cards=0)
    assert r.col.decks.by_name('Parent') is None
    assert r.col.decks.by_name('Parent::Child') is None
    assert r.col.decks.by_name('Keep') is not None
    assert len(before - card_ids(r)) == 2
    assert card_ids(r) == {siblings[1]}
    assert r.col.get_note(nid).card_ids() == [siblings[1]]
    assert list(r.col.get_note(nid).fields) == ['shared note', 'both sides']
    assert r.col.db.all('select * from cards where id=?', siblings[1]) == untouched


def test_delete_default_keeps_the_deck_but_reports_deleted_cards(runtime):
    r = runtime
    nid = add(r)
    before = set(r.col.get_note(nid).card_ids())
    assert r.col.decks.by_name('Default')['id'] == 1

    _, outcome = r.apply('delete_decks', {'deck_names': ['Default']})

    assert_receipt(outcome, deleted_decks=[], retained_decks=['Default'],
                   deleted_cards=1, retained_cards=0)
    assert r.col.decks.by_name('Default')['id'] == 1
    assert before - card_ids(r) == before
    assert not card_ids(r) and r.col.note_count() == 0


def test_delete_filtered_deck_returns_card_instead_of_reporting_it_deleted(runtime):
    r = runtime
    r.apply('create_deck', {'name': 'Source'})
    nid = add(r, deck='Source')
    cid = r.col.get_note(nid).card_ids()[0]
    original = r.col.get_card(cid)
    original_schedule = (original.did, original.type, original.queue, original.due,
                         original.ivl, original.factor, original.reps, original.lapses)
    filtered_deck_with_card(r, 'Filtered', cid)
    assert r.col.get_card(cid).odid == original.did
    before = card_ids(r)

    preview, outcome = r.apply('delete_decks', {'deck_names': ['Filtered']})

    assert preview['summary']['cards'] == 1 and preview['summary']['cards_to_remove'] == 0
    assert_receipt(outcome, deleted_decks=['Filtered'], retained_decks=[],
                   deleted_cards=0, retained_cards=1)
    assert r.col.decks.by_name('Filtered') is None
    assert r.col.decks.by_name('Source') is not None
    assert card_ids(r) == before
    returned = r.col.get_card(cid)
    assert returned.odid == 0
    assert (returned.did, returned.type, returned.queue, returned.due,
            returned.ivl, returned.factor, returned.reps, returned.lapses) == original_schedule
    assert list(r.col.get_note(nid).fields) == ['front', 'back']


def test_delete_original_deck_counts_its_card_while_card_is_in_filtered_deck(runtime):
    r = runtime
    r.apply('create_deck', {'name': 'Source'})
    nid = add(r, deck='Source')
    cid = r.col.get_note(nid).card_ids()[0]
    source_did = r.col.get_card(cid).did
    filtered_did = filtered_deck_with_card(r, 'Filtered', cid)
    assert r.col.get_card(cid).odid == source_did
    assert r.col.get_card(cid).did == filtered_did

    preview, outcome = r.apply('delete_decks', {'deck_names': ['Source']})

    assert preview['summary']['cards_to_remove'] == 1
    assert_receipt(outcome, deleted_decks=['Source'], retained_decks=[],
                   deleted_cards=1, retained_cards=0)
    assert r.col.decks.by_name('Source') is None
    assert r.col.decks.by_name('Filtered')['id'] == filtered_did
    assert cid not in card_ids(r)
    assert not card_ids(r) and r.col.note_count() == 0


def test_delete_more_than_summary_limit_reports_all_deleted_cards(runtime):
    r = runtime
    r.apply('create_deck', {'name': 'Many'})
    notes = [{'deck_name': 'Many', 'model_name': 'Basic',
              'fields': {'Front': f'bulk card {i}', 'Back': 'answer'}, 'tags': []}
             for i in range(101)]
    r.apply('add_notes', {'notes': notes, 'allow_duplicate': True})
    untouched_nid = add(r, fields={'Front': 'untouched', 'Back': 'keep'})
    untouched_cid = r.col.get_note(untouched_nid).card_ids()[0]
    untouched = r.col.db.all('select * from cards where id=?', untouched_cid)
    before = card_ids(r)
    assert len(before) == 102

    preview, outcome = r.apply('delete_decks', {'deck_names': ['Many']})

    assert preview['summary']['ids_truncated'] is True
    assert len(preview['summary']['card_ids']) == 100
    assert preview['summary']['cards_to_remove'] == 101
    assert_receipt(outcome, deleted_decks=['Many'], retained_decks=[],
                   deleted_cards=101, retained_cards=0)
    assert r.col.decks.by_name('Many') is None
    assert len(before - card_ids(r)) == 101
    assert card_ids(r) == {untouched_cid}
    assert r.col.note_count() == 1
    assert r.col.db.all('select * from cards where id=?', untouched_cid) == untouched
