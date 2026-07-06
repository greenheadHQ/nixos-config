"""Characterization tests for pure singlefile-bridge helpers.

run_curl and send_pushover are subprocess/network boundaries and are intentionally
left outside this pure-helper suite.
"""


def test_sanitize_filename_preserves_current_cleanup_rules(bridge_module):
    cases = [
        ("folder/Report: 2026?.html", "Report_2026_.html"),
        ("../../", "archive.html"),
        ("weird<>name", "weird_name.html"),
        (".hidden.", "hidden.html"),
        ("snapshot.xhtml", "snapshot.xhtml"),
    ]

    for raw, expected in cases:
        assert bridge_module.sanitize_filename(raw) == expected


def test_extract_boundary_handles_quoted_and_missing_boundary(bridge_module):
    assert (
        bridge_module.extract_boundary('multipart/form-data; boundary="abc123"')
        == "abc123"
    )
    assert bridge_module.extract_boundary("MULTIPART/FORM-DATA; BOUNDARY=plain") == "plain"
    assert bridge_module.extract_boundary("text/plain") is None


def test_parse_content_disposition_current_attribute_rules(bridge_module):
    parsed = bridge_module.parse_content_disposition(
        'form-data; name="file"; filename="archive.html"; ignored'
    )

    assert parsed == {
        "type": "form-data",
        "name": "file",
        "filename": "archive.html",
    }


def test_parse_multipart_body_returns_text_fields_and_file_part(bridge_module):
    boundary = "----fixture"
    body = (
        b"------fixture\r\n"
        b'Content-Disposition: form-data; name="url"\r\n'
        b"\r\n"
        b"https://example.com/article\r\n"
        b"------fixture\r\n"
        b'Content-Disposition: form-data; name="file"; filename="archive.html"\r\n'
        b"Content-Type: text/html\r\n"
        b"\r\n"
        b"<html>saved</html>\r\n"
        b"------fixture--\r\n"
    )

    text_fields, file_part = bridge_module.parse_multipart_body(body, boundary)

    assert text_fields == [("url", "https://example.com/article")]
    assert file_part == {
        "name": "file",
        "filename": "archive.html",
        "content": b"<html>saved</html>",
        "content_type": "text/html",
    }


def test_parse_multipart_body_missing_boundary_or_field_name_is_ignored(bridge_module):
    missing_boundary_body = (
        b"--actual\r\n"
        b'Content-Disposition: form-data; name="url"\r\n'
        b"\r\n"
        b"https://example.com/article\r\n"
        b"--actual--\r\n"
    )
    nameless_body = (
        b"--fixture\r\n"
        b"Content-Disposition: form-data\r\n"
        b"\r\n"
        b"value\r\n"
        b"--fixture--\r\n"
    )

    assert bridge_module.parse_multipart_body(missing_boundary_body, "other") == ([], None)
    assert bridge_module.parse_multipart_body(nameless_body, "fixture") == ([], None)


def test_parse_json_body_returns_dict_only(bridge_module):
    assert bridge_module.parse_json_body(b'{"assetId":"asset-1"}') == {
        "assetId": "asset-1"
    }
    assert bridge_module.parse_json_body(b'["not", "a", "dict"]') == {}
    assert bridge_module.parse_json_body(b"not-json") == {}
    assert bridge_module.parse_json_body(b"") == {}


def test_parse_ifexists_mode_normalizes_query_values(bridge_module):
    assert bridge_module.parse_ifexists_mode("") == "skip"
    assert bridge_module.parse_ifexists_mode("ifexists=overwrite") == "overwrite"
    assert (
        bridge_module.parse_ifexists_mode("url=x&ifexists=APPEND-RECRAWL")
        == "append-recrawl"
    )
    assert bridge_module.parse_ifexists_mode("ifexists=invalid") == "skip"
