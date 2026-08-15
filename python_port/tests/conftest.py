"""Shared test set-up for the port.

Everything runs headless: QT_QPA_PLATFORM=offscreen is set *before* PySide6 is imported
anywhere. Widget tests use pytest-qt's `qtbot`/`qapp`; pure-model tests never touch Qt.
"""
from __future__ import annotations

import json
import os
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import pytest

FIXTURES = Path(__file__).parent / "fixtures"


def pytest_configure(config):
    # QSettings/QStandardPaths must never touch the real user profile from tests.
    from PySide6.QtCore import QCoreApplication

    QCoreApplication.setOrganizationName("nettilor-tests")
    QCoreApplication.setApplicationName("pLayout-tests")


@pytest.fixture
def fixtures_dir() -> Path:
    return FIXTURES


@pytest.fixture
def fixture_json():
    """Load a fixture as plain JSON (no model involved)."""

    def load(name: str):
        with open(FIXTURES / name, encoding="utf-8") as f:
            return json.load(f)

    return load
