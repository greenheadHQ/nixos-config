"""Review-memo compatibility with representative real Anki 26.08 note types.

The imported fixture creates disposable collections and inert GUI callbacks;
there are no accounts, HTTP listeners, AnkiWeb calls, or production data here.
These checks cover the stock types below and one explicit custom template, not
every third-party note type or the iPhone editor's UI/rendering behavior.
"""

import base64
import copy

import pytest

from test_real_collection import add, runtime  # noqa: F401: register the fixture


MEMO_FIELD = '검토 메모'
LONG_MEMO = '\n\n'.join([
    '검토메모-원문보존: 답은 외웠지만 이유를 설명하지 못한다. 다음 검토에서 질문할 것.',
    '첫째, 정의와 구체적인 예시를 분리해 설명해 주세요.\n'
    '예시: 입력 → 처리 → 결과를 각각 써 보고 어떤 조건에서 달라지는지 비교하고 싶다.',
    '둘째, c97: 질문에 인용한 빈칸 예시 (힌트)를 어떻게 설명할지 궁금하다.\n'
    '빈칸 생성 기호를 그대로 붙이지 않고 일반 문장으로 질문한다.',
    '\n'.join(
        f'{index}. 긴 예시: 사과와 배를 비교할 때 공통점뿐 아니라 반례도 설명해 주세요. '
        '질문을 여러 문단으로 나누어도 공백, 한글, 숫자와 문장 끝까지 보존해야 한다.'
        for index in range(1, 13)
    ),
    '마지막 질문: 내용이 많으면 질문 두 개로 나누는 수정안을 보여 주세요.\n'
    '끝표식-메모전체읽기-✅',
])
assert len(LONG_MEMO) > 400


def _custom_type(r, name):
    """A declared custom type with conditions, two templates, and custom CSS."""
    model = r.col.models.new(name)
    for field in ('Question', 'Answer', 'Context'):
        r.col.models.add_field(model, r.col.models.new_field(field))
    for name, front, back in (
        ('Forward', '{{#Context}}<aside>{{Context}}</aside>{{/Context}}{{Question}}',
         '{{FrontSide}}<hr id=answer>{{Answer}}'),
        ('Reverse', '{{Answer}}', '{{FrontSide}}<hr id=answer>{{Question}}'),
    ):
        template = r.col.models.new_template(name)
        template.update(qfmt=front, afmt=back)
        r.col.models.add_template(model, template)
    model['css'] = '.card { color: #246; } aside { font-style: italic; }'
    r.col.models.add(model)
    return model['name']


def _case(r, kind):
    if kind == 'basic':
        return 'Basic', {'Front': '일반 질문', 'Back': '일반 답변'}, 1
    if kind == 'reversed':
        return 'Basic (and reversed card)', {'Front': '사과', 'Back': 'apple'}, 2
    if kind == 'cloze':
        return 'Cloze', {'Text': '{{c1::사과}}와 {{c2::배}}를 비교한다.',
                         'Back Extra': '기존 추가 설명'}, 2
    if kind == 'custom':
        name = _custom_type(r, 'Custom review-memo fixture')
        return name, {'Question': '조건부 질문', 'Answer': '조건부 답변',
                      'Context': '기존 문맥'}, 2
    assert kind == 'image-occlusion'
    r.col.add_image_occlusion_notetype()
    r.col.models._clear_cache()
    model = r.col.models.by_name('Image Occlusion')
    assert model is not None
    # Use the stock backend's semantic field indexes, including its dedicated
    # occlusion metadata, rather than replacing the stock type with plain Cloze.
    indexes = r.col._backend.get_image_occlusion_fields(model['id'])
    fields = {field['name']: '' for field in model['flds']}
    values = {
        indexes.occlusions: (
            '{{c1::image-occlusion:rect:left=.1:top=.1:width=.2:height=.2:oi=1}}\n'
            '{{c2::image-occlusion:rect:left=.5:top=.5:width=.2:height=.2:oi=1}}'
        ),
        indexes.image: '<img src="memo-fixture.png">',
        indexes.header: '합성 이미지 가리기 질문',
        indexes.back_extra: '기존 이미지 설명',
    }
    for index, value in values.items():
        fields[model['flds'][index]['name']] = value
    # A valid synthetic 1x1 PNG; no existing media are read or downloaded.
    png = base64.b64decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='
    )
    r.apply('store_media', {'filename': 'memo-fixture.png',
                            'data': base64.b64encode(png).decode()})
    return model['name'], fields, 2


def _card_state(r, nid):
    cards = sorted(r.col.get_note(nid).card_ids())
    rendered = {}
    for cid in cards:
        card = r.col.get_card(cid)
        rendered[cid] = (card.question(), card.answer())
    return {
        'cards': r.col.db.all('select * from cards where nid=? order by id', nid),
        'reviews': r.col.db.all(
            'select * from revlog where cid in (select id from cards where nid=?) order by id', nid),
        'rendered': rendered,
    }


def _readback(r, nid, value):
    assert r.col.get_note(nid)[MEMO_FIELD] == value
    returned = r.ac.notesInfo(notes=[nid])
    assert len(returned) == 1 and returned[0]['noteId'] == nid
    assert returned[0]['fields'][MEMO_FIELD]['value'] == value
    for cid in r.col.get_note(nid).card_ids():
        # Sibling cards point to one shared note; there is no per-card memo copy.
        assert r.col.get_card(cid).note()[MEMO_FIELD] == value


@pytest.mark.parametrize('kind', ['basic', 'reversed', 'cloze', 'image-occlusion', 'custom'])
def test_appended_memo_preserves_existing_content_cards_and_new_note_behavior(runtime, kind):
    r = runtime
    name, fields, count = _case(r, kind)
    nid = add(r, name, fields)
    card_ids = sorted(r.col.get_note(nid).card_ids())
    assert len(card_ids) == count
    r.apply('set_due_date', {'card_ids': card_ids, 'days': '3'})

    unrelated_name = _custom_type(r, 'Unrelated review-memo fixture')
    unrelated = add(r, unrelated_name, {'Question': '관계없는 질문',
                                      'Answer': '그대로 둘 답변', 'Context': ''})
    unrelated_note = r.col.db.all('select * from notes where id=?', unrelated)
    unrelated_cards = _card_state(r, unrelated)
    before = _card_state(r, nid)
    assert before['reviews'], 'Preservation must include nonempty review history.'
    model_before = copy.deepcopy(r.adapter.model_info(name))
    original_fields = dict(r.col.get_note(nid).items())
    backup_count = len(r.restored)

    preview, _ = r.apply('model_field_add', {
        'model_name': name, 'field_name': MEMO_FIELD,
        'index': len(model_before['fields']),
    }, schema=True)
    assert preview['schema_required'] and preview['backup_required']
    assert len(r.restored) == backup_count + 1
    model_after = r.adapter.model_info(name)
    assert model_after['fields'] == [*model_before['fields'],
                                    {'name': MEMO_FIELD, 'index': len(model_before['fields'])}]
    assert {key: value for key, value in model_after.items() if key != 'fields'} == {
        key: value for key, value in model_before.items() if key != 'fields'
    }
    assert _card_state(r, nid) == before
    _readback(r, nid, '')

    r.apply('update_fields', {'note_id': nid, 'fields': {MEMO_FIELD: LONG_MEMO}})
    _readback(r, nid, LONG_MEMO)
    assert _card_state(r, nid) == before
    assert {key: r.col.get_note(nid)[key] for key in original_fields} == original_fields
    assert all('검토메모-원문보존' not in question + answer
               for question, answer in before['rendered'].values())

    # Newly created notes inherit the appended field, whether left blank or
    # populated at creation. The supported plain-language memo creates no cards.
    blank = add(r, name, fields)
    _readback(r, blank, '')
    assert len(r.col.get_note(blank).card_ids()) == count
    fresh = add(r, name, {**fields, MEMO_FIELD: LONG_MEMO})
    _readback(r, fresh, LONG_MEMO)
    assert len(r.col.get_note(fresh).card_ids()) == count
    assert {key: r.col.get_note(fresh)[key] for key in fields} == fields

    # Updating through either sibling's parent note changes the same memo while
    # preserving every original card row, schedule, and rendered side.
    amended = LONG_MEMO + '\n\n추가 질문: 두 번째 방향의 문제도 같은 이유가 적용되나요?'
    shared_nid = r.col.get_card(card_ids[-1]).nid
    r.apply('update_fields', {'note_id': shared_nid, 'fields': {MEMO_FIELD: amended}})
    _readback(r, nid, amended)
    _readback(r, fresh, LONG_MEMO)
    assert _card_state(r, nid) == before
    assert r.col.db.all('select * from notes where id=?', unrelated) == unrelated_note
    assert _card_state(r, unrelated) == unrelated_cards
    assert r.adapter.model_info(name) == model_after
    # Export closes and reopens the actual collection. The memo must survive
    # that boundary, including paragraphs and text beyond the search preview.
    r.helper._export(str(r.root / 'backups' / 'memo-roundtrip.colpkg'), False, False)
    _readback(r, nid, amended)
    _readback(r, fresh, LONG_MEMO)
    assert _card_state(r, nid) == before


@pytest.mark.parametrize('kind', ['cloze', 'image-occlusion'])
def test_literal_cloze_markup_in_hidden_memo_really_generates_cards(runtime, kind):
    r = runtime
    name, fields, count = _case(r, kind)
    nid = add(r, name, fields)
    r.apply('model_field_add', {'model_name': name, 'field_name': MEMO_FIELD}, schema=True)
    before = _card_state(r, nid)
    memo = '\n'.join('{{c%d::메모에 인용한 구문}}' % ordinal for ordinal in range(3, 24))
    preview, _ = r.apply('update_fields', {'note_id': nid, 'fields': {MEMO_FIELD: memo}})
    # This is the reason for the documented input restriction, not a claim
    # that a hidden field is a safe container for arbitrary cloze source.
    assert preview['summary']['cards'] == count + 21
    assert preview['confirmation_required'] and preview['backup_required']
    assert len(r.col.get_note(nid).card_ids()) == count + 21
    after = _card_state(r, nid)
    assert all(row in after['cards'] for row in before['cards'])
    assert after['reviews'] == before['reviews']
    _readback(r, nid, memo)


@pytest.mark.parametrize('kind', ['basic', 'reversed', 'cloze', 'image-occlusion', 'custom'])
@pytest.mark.parametrize('clear_memo', [False, True], ids=['star-only', 'star-and-memo'])
def test_selected_review_cleanup_preserves_other_notes_and_card_state(runtime, kind, clear_memo):
    """Exercise existing mutations after a simulated explicit choice, not LLM consent enforcement."""
    r = runtime
    name, fields, card_count = _case(r, kind)
    r.apply('model_field_add', {'model_name': name, 'field_name': MEMO_FIELD}, schema=True)
    selected = [add(r, name, {**fields, MEMO_FIELD: LONG_MEMO}) for _ in range(2)]
    unfinished = add(r, name, {**fields, MEMO_FIELD: LONG_MEMO + '\n\n아직 해결하지 않은 질문'})
    all_notes = [*selected, unfinished]
    all_cards = [cid for nid in all_notes for cid in r.col.get_note(nid).card_ids()]
    assert len(all_cards) == card_count * 3
    r.apply('add_tags', {'note_ids': all_notes, 'tags': ['marked', 'keep::context']})
    r.apply('set_card_flags', {'card_ids': all_cards, 'flag': 4})
    r.apply('set_due_date', {'card_ids': all_cards, 'days': '3'})
    before_cards = {nid: _card_state(r, nid) for nid in all_notes}
    assert all(state['reviews'] for state in before_cards.values())
    before_fields = {nid: dict(r.col.get_note(nid).items()) for nid in all_notes}
    before_tags = {nid: set(r.col.get_note(nid).tags) for nid in all_notes}
    untouched = r.col.db.all('select * from notes where id=?', unfinished)
    model_before = copy.deepcopy(r.adapter.model_info(name))
    backup_count = len(r.restored)

    if clear_memo:
        preview, outcome = r.apply('update_fields_bulk', {
            'notes': [{'note_id': nid, 'fields': {MEMO_FIELD: ''}} for nid in selected],
        })
        assert preview['backup_required']
        for nid in selected:
            _readback(r, nid, '')
            assert 'marked' in r.col.get_note(nid).tags
        # Retrying the same operation cannot add another backup or replay changes.
        replay = r.ops.apply(preview['operation_id'], preview['preview_token'], True)
        assert replay['state'] == outcome['state'] == 'applied'
        assert len(r.restored) == backup_count + 1

    r.apply('remove_tags', {'note_ids': selected, 'tags': ['marked']})
    for nid in selected:
        expected_fields = {**before_fields[nid], MEMO_FIELD: ''} if clear_memo else before_fields[nid]
        assert dict(r.col.get_note(nid).items()) == expected_fields
        assert set(r.col.get_note(nid).tags) == before_tags[nid] - {'marked'}
        _readback(r, nid, expected_fields[MEMO_FIELD])
    assert r.col.db.all('select * from notes where id=?', unfinished) == untouched
    assert {nid: _card_state(r, nid) for nid in all_notes} == before_cards
    assert r.adapter.model_info(name) == model_before
    assert len(r.restored) == backup_count + int(clear_memo)
