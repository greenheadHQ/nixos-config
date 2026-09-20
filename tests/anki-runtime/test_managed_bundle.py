"""Full native definitions and restore candidates on real pinned Anki.

These checks intentionally include a candidate that changes card generation.
An unchanged supplied req array cannot replace the isolated native update trial.
"""
import copy

import pytest

from test_real_collection import HOST, add, load, runtime  # noqa: F401

bundle = load('anki_managed_bundle_runtime', HOST / 'managed_bundle.py')


def rows(r):
    return {table: r.col.db.all(f'select * from {table} order by id')
            for table in ('notes', 'cards', 'revlog')}


def test_complete_native_definition_excludes_identity_and_rejects_new_settings(runtime):
    r = runtime
    model = copy.deepcopy(r.col.models.by_name('Basic'))
    result = bundle.build_bundle(model, {'_synthetic.js': b'function synthetic() {}'})
    bundle.validate_bundle(result)
    assert set(result['definition']['flds'][0]) == set(model['flds'][0]) - {'id'}
    assert set(result['definition']['tmpls'][0]) == set(model['tmpls'][0]) - {'id'}
    assert result['definition']['req'] == model['req']
    changed = copy.deepcopy(model)
    changed.update(id=model['id'] + 1, mod=model['mod'] + 1, usn=model['usn'] + 1)
    assert bundle.build_bundle(changed, {'_synthetic.js': b'function synthetic() {}'}) == result
    changed['flds'][0]['futureBackendFlag'] = False
    with pytest.raises(bundle.ManagedBundleError, match='unsupported-settings'):
        bundle.canonical_model(changed)


def test_native_presentation_restore_preserves_all_note_card_and_review_rows(runtime):
    r = runtime
    model = copy.deepcopy(r.col.models.by_name('Basic'))
    r.col.models.add_field(model, r.col.models.new_field('검토 메모'))
    r.col.models.update_dict(model)
    r.col.models._clear_cache()
    nid = add(r, fields={'Front': 'question', 'Back': 'answer', '검토 메모': 'first\n\nsecond'})
    cid = r.col.get_note(nid).card_ids()[0]
    add(r, model='Basic (and reversed card)', fields={'Front': 'unrelated', 'Back': 'keep'})
    r.apply('add_tags', {'note_ids': [nid], 'tags': ['marked', 'keep']})
    r.apply('set_due_date', {'card_ids': [cid], 'days': '4'})
    r.col.set_user_flag_for_cards(4, [cid])
    before = rows(r)
    assert before['revlog']
    native = copy.deepcopy(r.col.models.by_name('Basic'))
    target = bundle.canonical_model(native)
    target['tmpls'][0]['qfmt'] = '<div>{{Front}}</div>'
    target['tmpls'][0]['afmt'] += '<p>Safe restored presentation</p>'
    target['css'] += '\n.card { margin: 1rem; }'
    candidate = bundle.native_from_definition(native, target)
    r.col.models.update_dict(candidate)
    r.col.models._clear_cache()
    observed = r.col.models.get(native['id'])
    assert bundle.canonical_model(observed) == target
    assert rows(r) == before
    assert observed['req'] == native['req']
    assert [f['id'] for f in observed['flds']] == [f['id'] for f in native['flds']]
    assert [t['id'] for t in observed['tmpls']] == [t['id'] for t in native['tmpls']]
    assert 'Safe restored presentation' in r.col.get_card(cid).answer()


def test_native_update_recomputes_generation_even_when_supplied_req_is_unchanged(runtime):
    r = runtime
    name = 'Basic (and reversed card)'
    nid = add(r, model=name, fields={'Front': 'question', 'Back': ''})
    native = copy.deepcopy(r.col.models.by_name(name))
    before_cards = r.col.get_note(nid).card_ids()
    assert len(before_cards) == 1
    target = bundle.canonical_model(native)
    target['tmpls'][1]['qfmt'] = '<div>{{Front}}</div>'
    # Both arrays still match before the backend sees the new qfmt. A restore
    # caller must trial this in its snapshot, compare req and complete rows,
    # and reject it before applying anything to the live collection.
    assert bundle.structural_definition(native) == bundle.structural_definition(target)
    candidate = bundle.native_from_definition(native, target)
    r.col.models.update_dict(candidate)
    r.col.models._clear_cache()
    after = r.col.models.get(native['id'])
    assert after['req'] != native['req']
    assert len(r.col.get_note(nid).card_ids()) == 2
    assert r.col.get_note(nid).card_ids() != before_cards
