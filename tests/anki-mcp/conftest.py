import os
import sys
import types
from pathlib import Path

import pytest

SRC = os.path.join(os.path.dirname(__file__), "..", "..", "modules", "nixos", "programs", "anki-mcp", "src")
sys.path.insert(0, os.path.abspath(SRC))
# Import pure helper components without loading Qt or opening a real profile.
package = types.ModuleType("anki_host_fixture")
package.__path__ = [str(Path(__file__).resolve().parents[2] / "modules/nixos/programs/anki-host/sync-addon")]
sys.modules[package.__name__] = package


@pytest.fixture
def anyio_backend():
    return "asyncio"
