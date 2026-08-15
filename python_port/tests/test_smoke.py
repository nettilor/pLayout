"""M0 smoke: the package imports, the version is set, Qt starts offscreen, fixtures parse."""


def test_package_imports_and_versions():
    import playout

    assert playout.__version__
    assert playout.MAC_VERSION == "1.4"


def test_qt_starts_offscreen(qapp):
    from PySide6.QtWidgets import QApplication

    assert isinstance(qapp, QApplication)


def test_mac_written_fixtures_are_json(fixture_json):
    for name in ("allfactors.plate", "overview.plate", "big384.plate"):
        doc = fixture_json(name)
        assert isinstance(doc["plates"], list) and doc["plates"]
        assert isinstance(doc["factors"], list) and doc["factors"]
