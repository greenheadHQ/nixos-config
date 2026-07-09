"""pytest loader for da-weekly-report."""
import os
import sys

import pytest


HERE = os.path.dirname(os.path.abspath(__file__))
PROGRAM_ROOT = os.path.dirname(HERE)
FILES_DIR = os.path.join(PROGRAM_ROOT, "files")
sys.path.insert(0, FILES_DIR)


@pytest.fixture(scope="session")
def weekly_report_module():
    import weekly_report  # type: ignore

    return weekly_report
