"""pytest fixture loader — analyzing-da-sessions tests."""
import json
import os
import sys

import pytest

# scripts/analyze.py를 sys.path에 추가하여 import 가능하게 함
HERE = os.path.dirname(os.path.abspath(__file__))
SKILL_ROOT = os.path.dirname(HERE)
SCRIPTS_DIR = os.path.join(SKILL_ROOT, "scripts")
sys.path.insert(0, SCRIPTS_DIR)


@pytest.fixture(scope="session")
def fixtures_dir():
    return os.path.join(HERE, "fixtures")


@pytest.fixture(scope="session")
def analyze_module():
    """scripts/analyze.py를 import한 모듈 객체."""
    import analyze  # type: ignore
    return analyze


def load_fixture_pair(fixtures_dir, name):
    """fixture 입력(.txt) + 기댓값(.expected.json) 쌍을 로드."""
    txt_path = os.path.join(fixtures_dir, f"{name}.txt")
    json_path = os.path.join(fixtures_dir, f"{name}.expected.json")
    with open(txt_path, "r") as fp:
        text = fp.read()
    with open(json_path, "r") as fp:
        expected = json.load(fp)
    return text, expected
