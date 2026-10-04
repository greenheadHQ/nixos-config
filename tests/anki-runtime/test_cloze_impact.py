"""Native Cloze parsing/card generation is the operation preview's count oracle."""
import pytest

from test_real_collection import add, runtime  # noqa: F401


def collection_rows(r):
    return {table: r.col.db.all(f'select * from {table} order by id')
            for table in ('col', 'notes', 'cards', 'revlog')}


def cloze_text(numbers, syntax):
    if syntax == 'comma':
        return '{{c' + ','.join(str(number) for number in numbers) + '::new}}'
    return ' '.join('{{c%03d::new}}' % number for number in numbers)


@pytest.mark.parametrize('action', ['add_notes', 'update_fields', 'update_fields_bulk'])
@pytest.mark.parametrize('syntax', ['comma', 'leading-zero'])
@pytest.mark.parametrize('card_count', [20, 21])
def test_native_cloze_generation_matches_preview_and_bulk_safety(runtime, action, syntax, card_count):
    r = runtime
    note_ids = []
    if action == 'add_notes':
        params = {'notes': [{'deck_name': 'Default', 'model_name': 'Cloze',
                   'fields': {'Text': cloze_text(range(1, card_count + 1), syntax)}, 'tags': []}],
                  'allow_duplicate': True}
    else:
        first = add(r, 'Cloze', {'Text': '{{c1::old}}', 'Back Extra': '{{c2::preserve}}'})
        note_ids.append(first)
        if action == 'update_fields_bulk':
            second = add(r, 'Cloze', {'Text': '{{c1::second}}', 'Back Extra': ''})
            note_ids.append(second)
        # Include retained c1, an unchanged field's c2, and (in bulk) another
        # note's c1. A global ordinal set or patched-fields-only parse is wrong.
        last = card_count - (len(note_ids) - 1)
        patch = {'note_id': first, 'fields': {'Text': cloze_text(range(3, last + 1), syntax)}}
        params = ({'notes': [patch, {'note_id': second, 'fields': {'Text': '{{c001::changed}}'}}]}
                  if action == 'update_fields_bulk' else patch)
    before = collection_rows(r)
    backups_before = len(r.restored)
    preview = r.ops.prepare(action, params)
    assert collection_rows(r) == before  # Unsaved parsing must not change the collection.
    assert preview['summary']['cards'] == card_count
    assert preview['confirmation_required'] is (card_count > 20)
    needs_backup = action != 'add_notes' or card_count > 20
    assert preview['backup_required'] is needs_backup
    if card_count > 20:
        with pytest.raises(r.error, match='explicit-confirmation-required'):
            r.ops.apply(preview['operation_id'], preview['preview_token'])
        assert collection_rows(r) == before and len(r.restored) == backups_before
    outcome = r.ops.apply(preview['operation_id'], preview['preview_token'], card_count > 20)
    assert outcome['state'] == 'applied'
    if action == 'add_notes':
        note_ids = [outcome['result']['results'][0]['noteId']]
    assert sum(len(r.col.get_note(nid).card_ids()) for nid in note_ids) == card_count
    assert len(r.restored) == backups_before + int(needs_backup)
    if action != 'add_notes':
        after = collection_rows(r)
        assert all(row in after['cards'] for row in before['cards'])
        assert after['revlog'] == before['revlog']
        assert r.col.get_note(first)['Back Extra'] == '{{c2::preserve}}'


@pytest.mark.parametrize('fields,ordinals', [
    ({'Text': 'plain text'}, [0]),
    ({'Text': '{{c1::unclosed'}, [0]),
    ({'Text': '{{c0001,0002,0002::valid}}'}, [0, 1]),
    ({'Text': '{{c1::outer {{c2::inner}}}}'}, [0, 1]),
    ({'Text': '{{c65535::last}} {{c65536::overflow}}'}, [499]),
    ({'Text': '{{c500,501::both capped}}'}, [499, 499]),
    ({'Text': '{{c١::unicode}} {{c0::zero}}'}, [0]),
    ({'Text': '{{c2::unclosed', 'Back Extra': '}} {{c3::valid}}'}, [2]),
    ({'Text': '{{c1\x1f,002::normalized}}'}, [0, 1]),
])
def test_native_cloze_edge_syntax_preview_is_read_only_and_matches_generation(runtime, fields, ordinals):
    r = runtime
    before = collection_rows(r)
    preview = r.ops.prepare('add_notes', {'notes': [{'deck_name': 'Default', 'model_name': 'Cloze',
                              'fields': fields, 'tags': []}], 'allow_duplicate': True})
    assert collection_rows(r) == before
    assert preview['summary']['cards'] == len(ordinals)
    # Direct native insertion accepts even malformed/empty Cloze notes that
    # AnkiConnect validation may reject. It independently verifies generation.
    note = r.col.new_note(r.col.models.by_name('Cloze'))
    for name, value in fields.items():
        note[name] = value
    r.col.add_note(note, 1)
    assert sorted(card.ord for card in note.cards()) == ordinals


def test_existing_capped_cloze_card_prevents_new_capped_ordinals(runtime):
    r = runtime
    nid = add(r, 'Cloze', {'Text': '{{c500::old}}', 'Back Extra': ''})
    card_ids = list(r.col.get_note(nid).card_ids())
    preview, _ = r.apply('update_fields', {'note_id': nid, 'fields': {'Text': '{{c501,65535::new}}'}})
    assert preview['summary']['cards'] == 1
    assert list(r.col.get_note(nid).card_ids()) == card_ids
