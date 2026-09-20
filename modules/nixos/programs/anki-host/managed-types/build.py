#!/usr/bin/env python3
"""Build reviewed managed content without importing the Anki/Qt add-on entrypoint."""
import argparse
import json
from pathlib import Path
import sys
import types


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="anki-host repository directory")
    parser.add_argument("output", type=Path, nargs="?", help="new materialized output directory")
    parser.add_argument("--refresh-version", action="store_true",
                        help="update only version.json after deliberate source changes")
    args = parser.parse_args()
    if args.refresh_version == (args.output is not None):
        parser.error("provide an output directory or --refresh-version, exclusively")
    package = types.ModuleType("anki_managed_source")
    package.__path__ = [str(args.source / "sync-addon")]
    sys.modules[package.__name__] = package
    from anki_managed_source.managed_source import VERSION_PATH, generated_version, materialize

    if args.refresh_version:
        result = generated_version(args.source)
        (args.source / VERSION_PATH).write_bytes(
            (json.dumps(result, sort_keys=True, indent=2) + "\n").encode("utf-8"))
    else:
        result = materialize(args.source, args.output)
    print(result["digest"])


if __name__ == "__main__":
    main()
