"""Offline SDK metadata export and comparison; never connect to Anki or OAuth.

A complete registration inventory is distinct from tools exposed in one turn.
Omitted observed fields are unknown; explicit null means observed absence.
"""

from __future__ import annotations

import argparse
import asyncio
from datetime import datetime, timezone
import json
from pathlib import Path
import re
from types import SimpleNamespace
from typing import Any

from mcp.server.fastmcp import FastMCP
from mcp.types import Tool

from .server import INSTRUCTIONS
from .tools import Deps, register_tools

SOURCES = {"source", "server", "chatgpt-registration", "chat-turn"}
TOOL_FIELDS = {field.alias or name for name, field in Tool.model_fields.items()}
HINTS = {"readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"}


class DisabledDependency:
    def __getattr__(self, name: str) -> Any:
        raise RuntimeError(f"metadata export must not access dependency: {name}")


async def export_catalog(*, field_chars: int, source: str = "source") -> dict[str, Any]:
    if source not in {"source", "server"}:
        raise ValueError("export source must be source or server")
    if type(field_chars) is not int or field_chars < 0:
        raise ValueError("field_chars must be a non-negative integer from the server configuration")
    disabled = DisabledDependency()
    mcp = FastMCP("anki", instructions=INSTRUCTIONS)
    register_tools(mcp, Deps(
        anki=disabled, helper=disabled, syncer=disabled, sync_status_file="",
        field_chars=field_chars, page_max=0, media_max_bytes=0,
        operations=SimpleNamespace(sync_enabled=False, lock=asyncio.Lock()),
        public_url="https://example.invalid", uploads=disabled,
    ))
    return {
        "source": source, "observed_at": datetime.now(timezone.utc).isoformat(),
        "complete": True, "instructions": INSTRUCTIONS,
        "tools": [tool.model_dump(mode="json", by_alias=True) for tool in
                  sorted(await mcp.list_tools(), key=lambda tool: tool.name)],
    }


def validate_catalog(catalog: Any) -> dict[str, dict[str, Any]]:
    if not isinstance(catalog, dict) or set(catalog) - {
        "source", "observed_at", "complete", "instructions", "tools",
    }:
        raise ValueError("catalog must contain only documented fields")
    if not isinstance(catalog.get("source"), str) or catalog["source"] not in SOURCES or type(catalog.get("complete")) is not bool:
        raise ValueError("catalog requires a known source and boolean complete")
    try:
        timestamp = datetime.fromisoformat(catalog["observed_at"])
        if timestamp.tzinfo is None:
            raise ValueError("timezone required")
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError("observed_at must be an ISO timestamp with timezone") from error
    if "instructions" in catalog and not isinstance(catalog["instructions"], (str, type(None))):
        raise ValueError("instructions must be text or null")
    tools = catalog.get("tools")
    if not isinstance(tools, list) or not tools:
        raise ValueError("tools must be a non-empty list; unavailable is not an empty inventory")
    indexed = {}
    for tool in tools:
        if not isinstance(tool, dict) or set(tool) - TOOL_FIELDS:
            raise ValueError("tool contains unsupported fields")
        name = tool.get("name")
        if not isinstance(name, str) or re.fullmatch(r"anki_[A-Za-z0-9_]+", name) is None:
            raise ValueError("tool requires an Anki tool name")
        if name in indexed:
            raise ValueError(f"duplicate tool: {name}")
        for field in ("title", "description"):
            if field in tool and not isinstance(tool[field], (str, type(None))):
                raise ValueError(f"{name}.{field} must be text or null")
        for field in ("inputSchema", "outputSchema", "_meta", "execution"):
            if field in tool and not isinstance(tool[field], dict) and not (
                field != "inputSchema" and tool[field] is None
            ):
                raise ValueError(f"{name}.{field} must be an object")
        if "icons" in tool and tool["icons"] is not None and not isinstance(tool["icons"], list):
            raise ValueError(f"{name}.icons must be a list or null")
        annotations = tool.get("annotations")
        if annotations is not None:
            if not isinstance(annotations, dict) or set(annotations) - (HINTS | {"title"}):
                raise ValueError(f"{name}.annotations contains unsupported fields")
            for hint in HINTS & annotations.keys():
                if annotations[hint] is not None and type(annotations[hint]) is not bool:
                    raise ValueError(f"{name}.annotations.{hint} must be boolean or null")
            if "title" in annotations and not isinstance(annotations["title"], (str, type(None))):
                raise ValueError(f"{name}.annotations.title must be text or null")
        indexed[name] = tool
    return indexed


def compare_catalogs(expected: Any, observed: Any, scope: str = "full") -> dict[str, Any]:
    if scope not in {"registration", "full"}:
        raise ValueError("scope must be registration or full")
    left, right = validate_catalog(expected), validate_catalog(observed)
    if expected["source"] not in {"source", "server"} or not expected["complete"]:
        raise ValueError("expected catalog must be complete source or server metadata")
    if "instructions" not in expected or any(set(tool) != TOOL_FIELDS for tool in left.values()):
        raise ValueError("expected catalog must include the complete SDK export")
    changed, unobserved, required_unknown = [], [], []

    def compare_field(path: str, before: Any, after: dict[str, Any], key: str, required: bool) -> None:
        if key not in after:
            unobserved.append(path)
            if required:
                required_unknown.append(path)
        elif json.dumps(before, sort_keys=True) != json.dumps(after[key], sort_keys=True):
            changed.append(path)

    compare_field("instructions", expected["instructions"], observed, "instructions", scope == "full")
    for name in sorted(left.keys() & right.keys()):
        for field in sorted(TOOL_FIELDS - {"name"}):
            path = f"tools.{name}.{field}"
            if field == "annotations" and isinstance(left[name][field], dict):
                hints = right[name].get(field)
                if hints is None and field in right[name]:
                    changed.append(path)
                    continue
                for hint in sorted(left[name][field]):
                    compare_field(f"{path}.{hint}", left[name][field][hint], hints or {}, hint,
                                  scope == "full" or hint == "readOnlyHint")
                for hint in sorted(set(hints or {}) - set(left[name][field])):
                    changed.append(f"{path}.{hint}")
            else:
                compare_field(path, left[name][field], right[name], field,
                              scope == "full" or field in {"description", "inputSchema"})
    missing, extra = sorted(left.keys() - right.keys()), sorted(right.keys() - left.keys())
    comparison = "turn-exposure" if observed["source"] == "chat-turn" else "metadata"
    comparable = observed["complete"] and comparison == "metadata"
    differences = bool(changed or missing or extra)
    status = ("unknown" if not comparable else "drift" if differences else
              "unknown" if required_unknown else "match")
    return {
        "scope": scope, "status": status,
        "full_status": ("unknown" if not comparable else "drift" if differences else
                        "unknown" if unobserved else "match"),
        "comparison": comparison, "complete": observed["complete"],
        "expected_source": expected["source"], "observed_source": observed["source"],
        "observed_at": observed["observed_at"],
        "counts": {"expected": len(left), "observed": len(right)},
        "missing_tools": missing, "extra_tools": extra,
        "changed": sorted(changed), "unobserved": sorted(unobserved),
    }


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _invalid_number(value: str) -> Any:
    raise ValueError(f"invalid JSON number: {value}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    export = commands.add_parser("export", help="export SDK metadata without credentials or service calls")
    export.add_argument("--source", choices=("source", "server"), default="source")
    export.add_argument("--field-chars", type=int, required=True,
                        help="configured ANKI_MCP_FIELD_CHARS (changes two input-schema defaults)")
    compare = commands.add_parser("compare", help="compare saved metadata; exit 0 match, 1 drift, 2 unknown/invalid")
    compare.add_argument("expected", type=Path)
    compare.add_argument("observed", type=Path)
    compare.add_argument("--scope", choices=("registration", "full"), default="full")
    args = parser.parse_args(argv)
    try:
        if args.command == "export":
            result, code = asyncio.run(export_catalog(field_chars=args.field_chars, source=args.source)), 0
        else:
            catalogs = [json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_unique_object,
                                   parse_constant=_invalid_number)
                        for path in (args.expected, args.observed)]
            result = compare_catalogs(*catalogs, scope=args.scope)
            code = {"match": 0, "drift": 1, "unknown": 2}[result["status"]]
    except (OSError, ValueError) as error:
        result, code = {"status": "invalid", "error": str(error)}, 2
    print(json.dumps(result, ensure_ascii=False, sort_keys=True, indent=2))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
