"""Canonical managed bytes and fail-closed disk reads, without Anki/Qt."""
import copy
import json
import os

import pytest

from anki_host_fixture.managed_bundle import (
    ManagedBundleError, build_bundle, canonical_model, diff_bundle, filename,
    load_bundle, native_from_definition, read_assets, structural_definition,
    validate_bundle,
)


def native():
    def field(name, ordinal):
        return dict(name=name, ord=ordinal, sticky=False, rtl=False, font='Arial',
                    size=20, description='', plainText=False, collapsed=False,
                    excludeFromSearch=False, id=100 + ordinal, tag=None, preventDeletion=False)
    return dict(id=123, name='CS 재활 Basic', type=0, mod=10, usn=3, sortf=0,
                did=None, flds=[field('Front', 0), field('Back', 1)],
                tmpls=[dict(name='Card', ord=0, qfmt='{{Front}}\r\n', afmt='{{Back}}',
                            bqfmt='', bafmt='', did=None, bfont='', bsize=0, id=222)],
                css='.card { color: black; }\n', latexPre='header', latexPost='tail',
                latexsvg=False, req=[[0, 'any', [0]]], originalStockKind=1)


def test_identity_timestamps_and_provenance_do_not_change_content_version():
    before = native()
    after = copy.deepcopy(before)
    after.update(id=234, mod=999, usn=44, originalId=123)
    after['flds'][0]['id'] += 30
    after['tmpls'][0]['id'] += 30
    assert build_bundle(before, {}) == build_bundle(after, {})
    # Provenance is deliberately not an accepted bundle payload: the registry
    # stores it beside the content, not inside the version being compared.
    bundle = build_bundle(before, {})
    bundle['git_sha'] = 'f' * 40
    with pytest.raises(ManagedBundleError, match='unsupported-settings'):
        validate_bundle(bundle)


@pytest.mark.parametrize('path,value', [
    (('css',), '.card { color: red; }'),
    (('tmpls', 0, 'qfmt'), '{{Front}}\n'),  # exact CRLF bytes matter
    (('tmpls', 0, 'afmt'), '{{Back}}!'),
    (('tmpls', 0, 'bqfmt'), 'browser'),
    (('flds', 0, 'sticky'), True),
    (('flds', 0, 'font'), 'Menlo'),
    (('flds', 0, 'description'), 'help'),
    (('sortf',), 1),
    (('req',), [[0, 'all', [0, 1]]]),
    (('latexsvg',), True),
])
def test_each_managed_setting_changes_digest_and_names_difference(path, value):
    before, after = native(), native()
    parent = after
    for key in path[:-1]:
        parent = parent[key]
    parent[path[-1]] = value
    a, b = build_bundle(before, {}), build_bundle(after, {})
    assert a['digest'] != b['digest']
    differences = diff_bundle(a, b)
    assert differences and all('{' not in item for item in differences)


def test_order_is_preserved_instead_of_sorting_fields_or_templates():
    before, after = native(), native()
    after['flds'].reverse()
    for index, field in enumerate(after['flds']):
        field['ord'] = index
    assert build_bundle(before, {})['digest'] != build_bundle(after, {})['digest']
    assert canonical_model(after)['flds'][0]['name'] == 'Back'


@pytest.mark.parametrize('change', [
    lambda m: m.update(futureSetting=True),
    lambda m: m['flds'][0].update(futureSetting=True),
    lambda m: m['tmpls'][0].update(futureSetting=True),
    lambda m: m['flds'][0].pop('plainText'),
    lambda m: m['tmpls'][0].update(did=100),
    lambda m: m.update(did=100),
    lambda m: m['flds'][0].update(ord=1),
    lambda m: m.update(sortf=True),
    lambda m: m.update(req=[]),
    lambda m: m.update(req=[[0, 'any', [99]]]),
    lambda m: m['flds'][0].update(sticky=1),
    lambda m: m['tmpls'][0].update(qfmt='bad\udfff'),
])
def test_unknown_missing_or_invalid_settings_are_unavailable(change):
    model = native()
    change(model)
    with pytest.raises(ManagedBundleError):
        canonical_model(model)


def test_assets_commit_names_and_actual_bytes_with_sorted_manifest():
    before = build_bundle(native(), {'_z.js': b'const x=1;\r\n', '_a.css': b'a{}'})
    assert [asset['filename'] for asset in before['assets']] == ['_a.css', '_z.js']
    validate_bundle(before, {'_z.js': b'const x=1;\r\n', '_a.css': b'a{}'})
    after = build_bundle(native(), {'_z.js': b'const x=1;\n'})
    assert diff_bundle(before, after) == ['assets._a.css.missing', 'assets._z.js.content']
    renamed = build_bundle(native(), {'_renamed.js': b'const x=1;\r\n', '_a.css': b'a{}'})
    assert renamed['digest'] != before['digest']
    with pytest.raises(ManagedBundleError, match='asset-content-mismatch'):
        validate_bundle(before, {'_z.js': b'other', '_a.css': b'a{}'})


@pytest.mark.parametrize('name', ['../a.js', 'a/b.js', 'a\\b.js', '.hidden.js', 'a..js',
                                 'a.png', 'a.JS', '/tmp/a.js', 'a.js\x00', 'a.js ', 'a.js:ads'])
def test_unsafe_asset_names_rejected(name):
    with pytest.raises(ManagedBundleError, match='unsafe-asset-filename'):
        filename(name)


def test_restore_materialization_preserves_ids_but_only_allows_presentation():
    current = native()
    target = canonical_model(current)
    target['css'] = 'new'
    target['tmpls'][0]['qfmt'] += '!'
    target['tmpls'][0]['afmt'] += '!'
    restored = native_from_definition(current, target)
    assert canonical_model(restored) == target
    assert restored['id'] == current['id']
    assert restored['flds'] == current['flds']
    assert restored['tmpls'][0]['id'] == current['tmpls'][0]['id']
    assert current['css'] != target['css']  # no caller mutation
    assert structural_definition(current) == structural_definition(target)
    for field, value in [('bqfmt', 'browser'), ('bsize', 30)]:
        changed = copy.deepcopy(target)
        changed['tmpls'][0][field] = value
        with pytest.raises(ManagedBundleError, match='restore-structure-changed'):
            native_from_definition(current, changed)
    changed = copy.deepcopy(target)
    changed['req'] = [[0, 'all', [0, 1]]]
    with pytest.raises(ManagedBundleError, match='restore-structure-changed'):
        native_from_definition(current, changed)


def test_read_assets_distinguishes_missing_from_failed_reads(tmp_path, monkeypatch):
    (tmp_path / '_a.js').write_bytes(b'good')
    result = read_assets(tmp_path, ['_a.js', '_missing.css'])
    assert result == {'files': {'_a.js': b'good'}, 'missing': ['_missing.css']}
    real_open = os.open
    def denied(path, *args, **kwargs):
        if path == '_a.js':
            raise PermissionError('denied')
        return real_open(path, *args, **kwargs)
    monkeypatch.setattr(os, 'open', denied)
    with pytest.raises(ManagedBundleError, match='asset-read-unavailable'):
        read_assets(tmp_path, ['_a.js'])
    with pytest.raises(ManagedBundleError, match='asset-directory-unavailable'):
        read_assets(tmp_path / 'missing-directory', ['_a.js'])


def test_read_assets_rejects_symlink_regular_or_dangling_and_special_file(tmp_path):
    (tmp_path / 'real.js').write_bytes(b'outside')
    (tmp_path / '_link.js').symlink_to(tmp_path / 'real.js')
    (tmp_path / '_dangling.js').symlink_to(tmp_path / 'does-not-exist')
    (tmp_path / '_directory.js').mkdir()
    os.mkfifo(tmp_path / '_fifo.js')
    for name in ['_link.js', '_dangling.js', '_directory.js', '_fifo.js']:
        with pytest.raises(ManagedBundleError):
            read_assets(tmp_path, [name])
    directory_link = tmp_path / 'link'
    directory_link.symlink_to(tmp_path, target_is_directory=True)
    with pytest.raises(ManagedBundleError):
        read_assets(directory_link, ['real.js'])


def test_replace_during_read_fails_instead_of_accepting_old_inode(tmp_path, monkeypatch):
    source = tmp_path / '_a.js'
    source.write_bytes(b'old')
    original_stat = os.stat
    def racing_stat(path, *args, **kwargs):
        if path == '_a.js':
            replacement = tmp_path / 'replacement'
            replacement.write_bytes(b'new')
            replacement.replace(source)
        return original_stat(path, *args, **kwargs)
    monkeypatch.setattr(os, 'stat', racing_stat)
    with pytest.raises(ManagedBundleError, match='asset-changed-during-read'):
        read_assets(tmp_path, ['_a.js'])


def test_materialized_bundle_loads_offline_and_checks_every_byte(tmp_path):
    assets = {'_asset.js': b'console.log(1);\n'}
    bundle = build_bundle(native(), assets)
    (tmp_path / 'assets').mkdir()
    (tmp_path / 'assets' / '_asset.js').write_bytes(assets['_asset.js'])
    path = tmp_path / 'bundle.json'
    path.write_text(json.dumps(bundle, ensure_ascii=False), encoding='utf-8')
    assert load_bundle(tmp_path) == (bundle, assets)
    (tmp_path / 'assets' / '_asset.js').write_bytes(b'changed')
    with pytest.raises(ManagedBundleError, match='asset-content-mismatch'):
        load_bundle(tmp_path)
    (tmp_path / 'assets' / '_asset.js').unlink()
    with pytest.raises(ManagedBundleError, match='baseline-asset-missing'):
        load_bundle(tmp_path)
    bundle['digest'] = '0' * 64
    path.write_text(json.dumps(bundle))
    with pytest.raises(ManagedBundleError, match='digest-mismatch'):
        load_bundle(tmp_path)


def test_bundle_definition_symlinks_and_duplicate_json_keys_are_rejected(tmp_path):
    (tmp_path / 'assets').mkdir()
    bundle = build_bundle(native(), {})
    actual = tmp_path / 'real.json'
    actual.write_text(json.dumps(bundle))
    source = tmp_path / 'bundle.json'
    source.symlink_to(actual)
    with pytest.raises(ManagedBundleError, match='source-unavailable'):
        load_bundle(tmp_path)
    source.unlink()
    source.write_text('{"schema_version": 1, "schema_version": 1}')
    with pytest.raises(ManagedBundleError, match='duplicate-json-key'):
        load_bundle(tmp_path)


@pytest.mark.parametrize('names', [['_a.js', '_a.js'], [{}], [None]])
def test_invalid_asset_lists_fail_with_managed_error(tmp_path, names):
    with pytest.raises(ManagedBundleError):
        read_assets(tmp_path, names)


def test_invalid_asset_mapping_key_fails_with_managed_error():
    with pytest.raises(ManagedBundleError):
        build_bundle(native(), {1: b'no', '_a.js': b'valid'})
