"""pytest loader for karakeep-singlefile-bridge tests."""
import importlib.util
import os

import pytest


HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE_PATH = os.path.join(os.path.dirname(HERE), "files", "singlefile-bridge.py")


@pytest.fixture(scope="session")
def bridge_module():
    spec = importlib.util.spec_from_file_location("karakeep_singlefile_bridge", SOURCE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load module spec from {SOURCE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
