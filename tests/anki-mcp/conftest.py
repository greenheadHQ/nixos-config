import os
import sys

import pytest

SRC = os.path.join(os.path.dirname(__file__), "..", "..", "modules", "nixos", "programs", "anki-mcp", "src")
sys.path.insert(0, os.path.abspath(SRC))


@pytest.fixture
def anyio_backend():
    return "asyncio"
