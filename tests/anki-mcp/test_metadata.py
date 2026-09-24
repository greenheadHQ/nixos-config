"""Metadata checks distinguish registration drift from incomplete observations."""

import asyncio
from copy import deepcopy
import json

import httpx
import pytest

from anki_mcp import server
from anki_mcp.metadata import compare_catalogs, export_catalog, main, validate_catalog


@pytest.fixture(scope="module")
def catalog():
    return asyncio.run(export_catalog(field_chars=400))


def registration(catalog):
    observed = deepcopy(catalog)
    observed["source"] = "chatgpt-registration"
    del observed["instructions"]
    # The app-only ticket tool (MCP Apps visibility ["app"]) is hidden from the registration list.
    observed["tools"] = [
        {"name": tool["name"], "description": tool["description"], "inputSchema": tool["inputSchema"],
         "annotations": {"readOnlyHint": tool["annotations"]["readOnlyHint"]}}
        for tool in observed["tools"] if tool["name"] != "anki_upload_ticket"
    ]
    return observed


def test_export_uses_sdk_without_building_services_or_clients(monkeypatch):
    def forbidden(*args, **kwargs):
        raise AssertionError("export accessed a service or credential")

    monkeypatch.setattr(server, "build", forbidden)
    monkeypatch.setattr(server, "read_local_key", forbidden)
    monkeypatch.setattr(httpx, "AsyncClient", forbidden)
    exported = asyncio.run(export_catalog(field_chars=417, source="server"))
    validate_catalog(exported)
    assert exported["source"] == "server" and exported["complete"]
    assert exported["instructions"] == server.INSTRUCTIONS
    names = [tool["name"] for tool in exported["tools"]]
    assert names == sorted(set(names)) and names
    assert all("inputSchema" in tool and "annotations" in tool for tool in exported["tools"])
    indexed = {tool["name"]: tool for tool in exported["tools"]}
    assert indexed["anki_find_notes"]["inputSchema"]["properties"]["max_field_chars"]["default"] == 417
    assert indexed["anki_find_cards"]["inputSchema"]["properties"]["max_chars"]["default"] == 417


def test_full_match_ignores_object_and_inventory_order(catalog):
    observed = json.loads(json.dumps(catalog, sort_keys=True))
    observed["tools"].reverse()
    result = compare_catalogs(catalog, observed)
    assert result["status"] == result["full_status"] == "match"
    assert result["unobserved"] == result["changed"] == []


def test_registration_scope_reports_unobserved_full_metadata(catalog):
    observed = registration(catalog)
    result = compare_catalogs(catalog, observed, "registration")
    assert result["status"] == "match" and result["full_status"] == "unknown"
    assert "instructions" in result["unobserved"]
    assert any(path.endswith("annotations.openWorldHint") for path in result["unobserved"])
    assert compare_catalogs(catalog, observed)["status"] == "unknown"


@pytest.mark.parametrize("field", ["description", "inputSchema", "annotations", "outputSchema", "instructions"])
def test_changed_metadata_is_drift_even_with_same_tool_count(catalog, field):
    observed = deepcopy(catalog)
    tool = observed["tools"][0]
    if field == "description":
        tool[field] += " changed"
    elif field == "inputSchema":
        # A missing nested schema member is a changed schema, not an unobserved field.
        del tool[field]["properties"][next(iter(tool[field]["properties"]))]
    elif field == "annotations":
        tool[field]["readOnlyHint"] = not tool[field]["readOnlyHint"]
    elif field == "outputSchema":
        tool[field] = {"type": "string"}
    else:
        observed[field] += " changed"
    result = compare_catalogs(catalog, observed, "registration")
    assert result["status"] == result["full_status"] == "drift"
    assert result["counts"]["expected"] == result["counts"]["observed"]
    path = "instructions" if field == "instructions" else f"tools.{tool['name']}.{field}"
    assert any(changed.startswith(path) for changed in result["changed"])


def test_missing_and_added_tools_are_named(catalog):
    observed = deepcopy(catalog)
    old_name = observed["tools"][0]["name"]
    observed["tools"][0]["name"] = "anki_new_tool"
    result = compare_catalogs(catalog, observed)
    assert result["status"] == "drift"
    assert result["missing_tools"] == [old_name] and result["extra_tools"] == ["anki_new_tool"]


def test_app_only_tools_may_be_absent_only_from_model_views(catalog):
    observed = registration(catalog)
    result = compare_catalogs(catalog, observed, "registration")
    assert result["status"] == "match" and result["missing_tools"] == []
    assert result["counts"]["expected"] == result["counts"]["observed"]
    observed["tools"] = [tool for tool in observed["tools"] if tool["name"] != "anki_upload_image"]
    assert compare_catalogs(catalog, observed, "registration")["missing_tools"] == ["anki_upload_image"]
    served = deepcopy(catalog)
    served["source"] = "server"
    served["tools"] = [tool for tool in served["tools"] if tool["name"] != "anki_upload_ticket"]
    result = compare_catalogs(catalog, served)
    assert result["status"] == "drift" and result["missing_tools"] == ["anki_upload_ticket"]


@pytest.mark.parametrize("kind", ["incomplete", "turn"])
def test_partial_inventory_and_turn_exposure_never_establish_drift(catalog, kind):
    observed = registration(catalog)
    observed["tools"].pop()
    if kind == "incomplete":
        observed["complete"] = False
    else:
        observed["source"] = "chat-turn"
    result = compare_catalogs(catalog, observed, "registration")
    assert result["status"] == result["full_status"] == "unknown"
    assert result["comparison"] == ("turn-exposure" if kind == "turn" else "metadata")
    assert len(result["missing_tools"]) == 1


def test_count_only_inventory_does_not_pass(catalog):
    observed = registration(catalog)
    observed["tools"] = [{"name": tool["name"]} for tool in observed["tools"]]
    result = compare_catalogs(catalog, observed, "registration")
    assert result["status"] == "unknown"
    assert any(path.endswith(".inputSchema") for path in result["unobserved"])


def test_explicit_absence_differs_from_unobserved(catalog):
    observed = registration(catalog)
    observed["tools"][0]["annotations"] = None
    assert compare_catalogs(catalog, observed, "registration")["status"] == "drift"


@pytest.mark.parametrize("change", [
    lambda c: c.update(tools=[]),
    lambda c: c["tools"].append(c["tools"][0]),
    lambda c: c.update(complete="true"),
    lambda c: c.update(source=[]),
    lambda c: c.update(observed_at="2026-09-22"),
    lambda c: c.update(unrecognized=True),
    lambda c: c["tools"][0].update(inputSchema=None),
    lambda c: c["tools"][0].update(description=1),
    lambda c: c["tools"][0].update(input_schema={}),
    lambda c: c["tools"][0]["annotations"].update(readOnlyHint=1),
    lambda c: c["tools"][0]["annotations"].update(readonlyHint=True),
])
def test_malformed_observations_are_rejected(catalog, change):
    observed = deepcopy(catalog)
    change(observed)
    with pytest.raises(ValueError):
        compare_catalogs(catalog, observed)


def test_expected_must_be_a_complete_sdk_export(catalog):
    with pytest.raises(ValueError, match="complete SDK export"):
        expected = deepcopy(catalog)
        del expected["tools"][0]["outputSchema"]
        compare_catalogs(expected, catalog)
    with pytest.raises(ValueError, match="complete source or server"):
        compare_catalogs(registration(catalog), catalog)


@pytest.mark.parametrize("scope,alter,code,status", [
    ("registration", False, 0, "match"), ("full", False, 2, "unknown"),
    ("registration", True, 1, "drift"),
])
def test_cli_returns_scope_specific_exit_codes(catalog, tmp_path, capsys, scope, alter, code, status):
    expected, observed = tmp_path / "expected.json", tmp_path / "observed.json"
    expected.write_text(json.dumps(catalog))
    view = registration(catalog)
    if alter:
        view["tools"].pop()
    observed.write_text(json.dumps(view))
    assert main(["compare", str(expected), str(observed), "--scope", scope]) == code
    assert json.loads(capsys.readouterr().out)["status"] == status


@pytest.mark.parametrize("contents", ['{"source":"source","source":"server"}', '{"tools":NaN}', '{'])
def test_cli_rejects_duplicate_keys_and_invalid_json(tmp_path, capsys, contents):
    path = tmp_path / "invalid.json"
    path.write_text(contents)
    assert main(["compare", str(path), str(path)]) == 2
    assert json.loads(capsys.readouterr().out)["status"] == "invalid"


def test_cli_export(capsys):
    assert main(["export", "--field-chars", "400"]) == 0
    validate_catalog(json.loads(capsys.readouterr().out))
