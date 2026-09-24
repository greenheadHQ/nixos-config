"""Public MCP managed tools expose only the intended server-owned capability."""

from types import SimpleNamespace

import pytest
from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.exceptions import ToolError

from anki_mcp.managed import DEFAULT_MODEL
from anki_mcp.operations import OperationService
from anki_mcp.tools import Deps, register_tools
from anki_mcp.upload import UploadTickets
from test_managed_service import FakeManagedHelper
from test_operation_service import Syncer


TOOLS = {"anki_managed_model_check", "anki_managed_model_history", "anki_restore_managed_model",
         "anki_managed_restore_status"}


def setup(tmp_path):
    helper, syncer = FakeManagedHelper(), Syncer()
    mcp = FastMCP("managed-tests")
    register_tools(mcp, Deps(anki=SimpleNamespace(), helper=helper, syncer=syncer,
        sync_status_file=str(tmp_path / "status.json"), field_chars=1000, page_max=100,
        operations=OperationService(helper, syncer, None, sync_enabled=True), media_max_bytes=100,
        public_url="https://anki.example", uploads=UploadTickets(120)))
    return mcp, helper, syncer


async def call(mcp, tool, arguments):
    result = await mcp.call_tool(tool, arguments)
    return result[1] if isinstance(result, tuple) else result


@pytest.mark.anyio
async def test_check_and_history_preserve_deterministic_host_results(tmp_path):
    mcp, helper, syncer = setup(tmp_path)
    result = await call(mcp, "anki_managed_model_check", {})
    assert result["status"] == "drift" and result["changes"] == [{"path": "css"}]
    assert result["model_name"] == DEFAULT_MODEL and not result["freshness"]["mobile_upload_confirmed"]
    result = await call(mcp, "anki_managed_model_history", {"model_name": "Unmanaged", "limit": 7, "offset": 14})
    assert result["model_name"] == "Unmanaged"
    assert helper.calls[-1] == ("/managed/history", {"model_name": "Unmanaged", "limit": 7, "offset": 14})
    assert not syncer.calls


@pytest.mark.anyio
async def test_restore_preview_confirmation_and_readback_end_to_end(tmp_path):
    mcp, helper, syncer = setup(tmp_path)
    result = await call(mcp, "anki_restore_managed_model", {"request_id": "managed001", "confirm": True})
    assert result["state"] == "prepared" and helper.apply_count == 0
    result = await call(mcp, "anki_restore_managed_model", {
        "request_id": "managed001", "preview_token": result["preview_token"], "confirm": True})
    assert result["state"] == "applied" and result["sync"]["state"] == "synced" and helper.apply_count == 1
    reread = await call(mcp, "anki_managed_restore_status", {"request_id": "managed001"})
    assert reread == result and syncer.calls == [None, None, 1000]


@pytest.mark.anyio
async def test_catalog_marks_strict_capability_and_approval_delivery_limits(tmp_path):
    mcp, _helper, _syncer = setup(tmp_path)
    tools = {tool.name: tool for tool in await mcp.list_tools()}
    for name in TOOLS:
        assert tools[name].inputSchema["additionalProperties"] is False
    restore = tools["anki_restore_managed_model"]
    assert set(restore.inputSchema["properties"]) == {"model_name", "request_id", "preview_token", "confirm"}
    assert not restore.annotations.readOnlyHint and restore.annotations.openWorldHint and restore.annotations.destructiveHint
    assert "not an independent human authentication" in " ".join(restore.description.split())
    assert "not reception or UI verification" in restore.description
    assert "fresh per-device" in restore.description and "never auto-select Download" in restore.description
    assert "unmanaged" in tools["anki_models"].description
    for name in ("anki_add_notes", "anki_update_note_fields", "anki_update_notes_fields"):
        assert "anki_managed_model_check" in tools[name].description


@pytest.mark.anyio
@pytest.mark.parametrize("tool,args", [
    ("anki_managed_model_check", {"digest": "a" * 64}),
    ("anki_managed_model_history", {"raw": True}),
    ("anki_restore_managed_model", {"digest": "a" * 64}),
    ("anki_restore_managed_model", {"payload": {"css": "evil"}}),
    ("anki_restore_managed_model", {"schema_action": "model_field_remove"}),
    ("anki_restore_managed_model", {"root_approval": True}),
    ("anki_restore_managed_model", {"filename": "../../escape.js"}),
    ("anki_restore_managed_model", {"data": "arbitrary bytes"}),
    ("anki_managed_restore_status", {"request_id": "managed001", "confirm": True}),
])
async def test_unknown_top_level_payloads_are_rejected_instead_of_ignored(tmp_path, tool, args):
    mcp, helper, syncer = setup(tmp_path)
    with pytest.raises(ToolError, match="Extra inputs are not permitted"):
        await call(mcp, tool, args)
    assert not helper.calls and not syncer.calls


@pytest.mark.anyio
@pytest.mark.parametrize("tool,args", [
    ("anki_managed_model_check", {"model_name": ""}),
    ("anki_managed_model_check", {"model_name": 7}),
    ("anki_managed_model_history", {"limit": True}),
    ("anki_managed_model_history", {"limit": 0}),
    ("anki_managed_model_history", {"limit": 101}),
    ("anki_managed_model_history", {"offset": -1}),
    ("anki_restore_managed_model", {"confirm": 1}),
    ("anki_restore_managed_model", {"confirm": "true"}),
    ("anki_restore_managed_model", {"preview_token": ""}),
    ("anki_restore_managed_model", {"request_id": "../escape"}),
    ("anki_managed_restore_status", {"request_id": "short"}),
])
async def test_invalid_inputs_stop_before_any_effect(tmp_path, tool, args):
    mcp, helper, syncer = setup(tmp_path)
    with pytest.raises(ToolError):
        await call(mcp, tool, args)
    assert not helper.calls and not syncer.calls
