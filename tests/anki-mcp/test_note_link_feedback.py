"""Stored-reference diagnostics must never change the outcome of a write."""

from collections import Counter
import json

import pytest

from anki_host_fixture import note_link_feedback as links
from anki_host_fixture.operations import atomic_json
from test_host_operations import engine
from test_tools import FakeAnki, make_mcp


TARGET = 1700000000000
MARKER = f'[reference|nid{TARGET}]'


@pytest.mark.parametrize('source', [MARKER, f'[a <b>bold</b> title|nid{TARGET}]',
    f'[a &amp; b|nid{TARGET}]', f'[escaped \\[ title|nid{TARGET}]',
    f'<p>{MARKER}</p>', f'<span>{MARKER}</span>'])
def test_candidates_accept_text_and_inline_markup(source):
    assert links.candidates(source) == Counter({TARGET: 1})


@pytest.mark.parametrize('source', [
    f'<{tag}>{MARKER}</{tag}>' for tag in ('pre', 'code', 'script', 'style', 'textarea', 'a', 'math', 'mjx-container')
] + [f'<span class="katex">{MARKER}</span>', f'<i title="{MARKER}">title</i>',
     f'<!-- {MARKER} -->', f'`{MARKER}`', f'``literal ` {MARKER}``',
     f'```text\n{MARKER}\n```', f'~~~text\n{MARKER}\n~~~', f'~~~text\n{MARKER}',
     f'\\({MARKER}\\)', f'\\[{MARKER}\\]', f'$${MARKER}$$', f'${MARKER}$',
     f'<div>[cross</div><div>block|nid{TARGET}]</div>',
     f'[cross<code>code</code>boundary|nid{TARGET}]',
     f'<pre><b>nested</b>{MARKER}</pre>', f'<script/>{MARKER}'])
def test_common_literal_examples_and_nontext_are_not_references(source):
    assert links.candidates(source) == Counter()


def test_excluded_content_does_not_hide_following_real_reference():
    assert links.candidates(f'<pre><b>{MARKER}</b></pre>{MARKER}') == Counter({TARGET: 1})
    assert links.candidates(f'```\n{MARKER}\n```\n{MARKER}') == Counter({TARGET: 1})


def test_snapshot_counts_only_missing_targets_and_does_not_retain_text():
    model = {1: ['Front', 'Back']}
    rows = [(123, 1, f'private title\x1f{MARKER} {MARKER}'),
            (456, 1, f'question\x1f[exists|nid0000000000123]')]
    view = links.snapshot(rows, model)
    assert view == {'notes': 2, 'missing': Counter({(123, 'Back', TARGET): 2})}
    assert 'private title' not in repr(view)
    with pytest.raises(ValueError, match='field-count-mismatch'):
        links.snapshot([(1, 1, 'missing delimiter')], model)


def test_occurrence_increases_count_while_unchanged_existing_dangling_does_not():
    before = {'notes': 2, 'missing': Counter({(1, 'Back', TARGET): 1, (2, 'Front', TARGET): 1})}
    after = {'notes': 1, 'missing': Counter({(1, 'Back', TARGET): 2})}
    check = links.compare(before, after)
    assert check['new_missing_occurrences'] == check['new_missing_references'] == 1
    assert check['references'] == [{'source_note_id': 1, 'field_name': 'Back',
                                     'target_note_id': TARGET, 'new_occurrences': 1}]
    assert not check['truncated']
    assert links.compare(after, after)['references'] == []


def test_large_diagnostic_has_exact_totals_and_bounded_pointer_list():
    after = {'notes': 200, 'missing': Counter({(n, 'Back', TARGET): 2 for n in range(200)})}
    check = links.compare({'notes': 200, 'missing': Counter()}, after)
    assert check['new_missing_occurrences'] == 400
    assert check['new_missing_references'] == 200
    assert len(check['references']) == links.MAX_REFERENCES
    assert check['truncated']


def snapshots(adapter, failure=None):
    calls = []
    def read():
        stage = 'after-write' if adapter.calls else 'before-write'
        calls.append(stage)
        if stage == failure:
            raise RuntimeError('private title /private/path must never reach receipt')
        return {'notes': 1, 'missing': Counter({(1, 'Back', TARGET): 1} if adapter.calls else {})}
    adapter.note_link_snapshot = read
    return calls


@pytest.mark.parametrize('write_state', ['applied', 'partial', 'unknown'])
@pytest.mark.parametrize('failure', [None, 'before-write', 'after-write'])
def test_diagnostic_failures_and_retries_keep_the_original_write_outcome(tmp_path, write_state, failure):
    ops, adapter = engine(tmp_path)
    adapter.result = {'state': write_state}
    adapter.fail = write_state == 'unknown'
    calls = snapshots(adapter, failure)
    params = {'note_id': 1, 'fields': {'Back': 'private note content'}}
    preview = ops.prepare('update_fields', params, 'link-feedback-retry')
    assert calls == []
    outcome = ops.apply(preview['operation_id'], preview['preview_token'])
    assert outcome['state'] == write_state
    if write_state != 'unknown':
        assert outcome['sync']['state'] == 'pending'
    check = outcome['link_check']
    if failure:
        assert check == {'state': 'unavailable', 'scope': links.SCOPE, 'stage': failure, 'error': 'RuntimeError'}
    else:
        assert check['state'] == 'checked' and check['new_missing_occurrences'] == 1
    assert ops.prepare('update_fields', params, 'link-feedback-retry') == outcome
    assert ops.apply(preview['operation_id'], preview['preview_token']) == outcome
    assert ops.status(preview['operation_id']) == outcome
    assert ops.history()['operations'] == [outcome]
    restarted, _ = engine(tmp_path)
    assert restarted.status(preview['operation_id']) == outcome
    assert len(adapter.calls) == 1
    assert calls == (['before-write'] if failure == 'before-write' else ['before-write', 'after-write'])
    journal = ops._path(preview['operation_id']).read_text()
    assert 'private note content' not in journal and 'private title' not in journal and '/private/path' not in journal


def test_interrupted_check_is_explicitly_unavailable_and_never_repeated(tmp_path):
    ops, adapter = engine(tmp_path)
    p = ops.prepare('update_fields', {'note_id': 1, 'fields': {'Back': 'change'}}, 'interrupted-link-check')
    record = ops._read(p['operation_id'])
    record.update(state='applying', link_check={'state': 'pending', 'scope': links.SCOPE})
    atomic_json(ops._path(p['operation_id']), record)
    restarted, _ = engine(tmp_path)
    outcome = restarted.apply(p['operation_id'], p['preview_token'])
    assert outcome['state'] == 'unknown'
    assert outcome['link_check'] == {'state': 'unavailable', 'scope': links.SCOPE, 'stage': 'interrupted'}
    assert not adapter.calls


def test_unsupported_actions_do_not_scan(tmp_path):
    ops, adapter = engine(tmp_path)
    calls = snapshots(adapter)
    p = ops.prepare('add_tags', {'note_ids': [1], 'tags': ['tag']})
    outcome = ops.apply(p['operation_id'], p['preview_token'])
    assert 'link_check' not in outcome and not calls


@pytest.mark.anyio
async def test_mcp_response_and_status_keep_link_check_and_explain_its_scope(tmp_path):
    from anki_mcp.server import INSTRUCTIONS
    fake = FakeAnki()
    # This fake records mutations under operation_calls, not calls.
    fake.note_link_snapshot = lambda: {'notes': 1, 'missing': Counter({(1, 'Back', TARGET): 1}
                                                                         if fake.operation_calls else {})}
    mcp = make_mcp(fake, tmp_path)
    _, out = await mcp.call_tool('anki_update_note_fields', {'note_id': 1, 'fields': {'Back': MARKER},
                                                           'request_id': 'mcp-link-feedback'})
    assert out['state'] == 'applied'
    assert out['link_check']['new_missing_occurrences'] == 1
    _, status = await mcp.call_tool('anki_operation_status', {'operation_id': out['operation_id']})
    assert status['link_check'] == out['link_check']
    assert 'link_check' in INSTRUCTIONS and 'stored' in INSTRUCTIONS and 'Do not repeat' in INSTRUCTIONS


def test_postwrite_crash_keeps_durable_success_and_does_not_rerun(tmp_path):
    ops, adapter = engine(tmp_path)
    def read():
        if adapter.calls:
            raise KeyboardInterrupt('simulate process termination during diagnostic')
        return {'notes': 1, 'missing': Counter()}
    adapter.note_link_snapshot = read
    p = ops.prepare('update_fields', {'note_id': 1, 'fields': {'Back': 'change'}}, 'postwrite-crash')
    with pytest.raises(KeyboardInterrupt):
        ops.apply(p['operation_id'], p['preview_token'])
    restarted, _ = engine(tmp_path)
    out = restarted.apply(p['operation_id'], p['preview_token'])
    assert out['state'] == 'applied' and out['sync']['state'] == 'pending'
    assert out['link_check']['state'] == 'unavailable'
    assert out['link_check']['stage'] == 'interrupted'
    assert len(adapter.calls) == 1


def test_baseline_is_after_restore_and_not_the_earlier_prepare(tmp_path):
    ops, adapter = engine(tmp_path)
    stale = {'notes': 1, 'missing': Counter()}
    adapter.note_link_snapshot = lambda: stale
    p = ops.prepare('update_fields', {'note_id': 1, 'fields': {'Back': 'change'}}, 'late-baseline')
    def restore(_):
        stale['missing'][(1, 'Front', TARGET)] = 1
        return {'mirrored': True}
    ops.restore = restore
    out = ops.apply(p['operation_id'], p['preview_token'])
    assert out['state'] == 'applied' and out['link_check']['new_missing_occurrences'] == 0


@pytest.mark.parametrize('ticks', ['```', '````'])
def test_closed_inline_code_is_not_an_unclosed_fence(ticks):
    assert links.candidates(f'{ticks}literal{ticks}\n{MARKER}') == Counter({TARGET: 1})


def test_fence_closing_requires_no_trailing_text():
    assert not links.candidates(f'~~~text\n~~~not a closer\n{MARKER}\n~~~')
    assert links.candidates(f'<div>```</div>{MARKER}<div>```</div>{MARKER}') == Counter({TARGET: 1})


@pytest.mark.parametrize('count', range(5))
def test_whole_marker_backslashes_remain_desktop_reference_candidates(count):
    assert links.candidates('\\' * count + MARKER) == Counter({TARGET: 1})


def test_br_is_a_link_boundary_but_preserves_markdown_fence_lines():
    assert links.candidates(f'[line<br>break|nid{TARGET}]') == Counter()
    assert links.candidates(f'```text<br>{MARKER}<br>```<br>{MARKER}') == Counter({TARGET: 1})


@pytest.mark.parametrize('wrapper', [
    '<pre>{}</pre>', '<code>{}</code>', '`{}`', '```text\n{}\n```',
    r'\({}\)', '<math>{}</math>',
])
def test_backslashed_marker_inside_code_fence_or_math_remains_excluded(wrapper):
    assert links.candidates(wrapper.format('\\' + MARKER)) == Counter()
