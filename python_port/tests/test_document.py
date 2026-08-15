"""PlateDocument — the undo funnel, files, autosave."""
from dataclasses import replace

from playout.editor.document import PlateDocument
from playout.model.layout import Layout, LayoutDecodeError, loads


def paint_first_well(layout: Layout) -> Layout:
    f = layout.factors[0]
    return layout.with_plate(0, layout.plates[0].set_level_id(f.levels[0].id, f.id, 0))


def test_mutate_is_a_no_op_when_nothing_changes():
    doc = PlateDocument()
    seen = []
    doc.layout_changed.connect(seen.append)
    assert doc.mutate("Nothing", lambda layout: layout) is False
    assert doc.mutate("Nothing", lambda layout: replace(layout, notes=layout.notes)) is False
    assert doc.undo_stack.count() == 0 and seen == [] and not doc.is_dirty


def test_every_edit_is_one_named_undo_step_and_signals_the_new_layout():
    doc = PlateDocument()
    seen = []
    doc.layout_changed.connect(seen.append)
    before = doc.layout
    assert doc.mutate("Paint Wells", paint_first_well) is True
    assert doc.undo_stack.count() == 1 and doc.undo_stack.undoText() == "Paint Wells"
    assert seen == [doc.layout] and doc.layout != before and doc.is_dirty
    doc.undo_stack.undo()
    assert doc.layout == before and seen[-1] == before
    doc.undo_stack.redo()
    assert doc.layout != before and doc.undo_stack.undoText() == "Paint Wells"


def test_undo_is_unlimited_like_the_mac():
    doc = PlateDocument()
    assert doc.undo_stack.undoLimit() == 0
    for i in range(50):
        doc.mutate("Note", lambda layout, i=i: replace(layout, notes=str(i)))
    assert doc.undo_stack.count() == 50


def test_save_load_and_clean_state(tmp_path):
    doc = PlateDocument()
    doc.mutate("Paint Wells", paint_first_well)
    target = tmp_path / "a.plate"
    assert doc.save(target) is True
    assert doc.path == target and not doc.is_dirty and doc.display_name == "a"
    again = PlateDocument.open(target)
    assert again.layout == doc.layout and again.path == target
    text = target.read_text(encoding="utf-8")
    assert text.startswith('{\n  "factors" : [') and "\r\n" not in text
    doc.mutate("Note", lambda layout: replace(layout, notes="x"))
    assert doc.is_dirty
    doc.undo_stack.undo()
    assert not doc.is_dirty  # back at the clean index


def test_open_refuses_what_the_mac_refuses(tmp_path):
    bad = tmp_path / "bad.plate"
    bad.write_text('{"orientation": "sideways"}', encoding="utf-8")
    try:
        PlateDocument.open(bad)
    except LayoutDecodeError:
        pass
    else:
        raise AssertionError("expected LayoutDecodeError")


def test_untitled_documents_never_autosave_and_save_now_is_safe():
    doc = PlateDocument()
    doc.mutate("Paint Wells", paint_first_well)
    assert doc.is_untitled and doc.display_name == "Untitled"
    assert doc.save() is False            # nowhere to save
    assert doc.save_now() is True         # nothing to flush


def test_autosave_writes_in_place_after_the_debounce(tmp_path, qapp):
    from PySide6.QtTest import QTest

    from playout.editor import document as document_module

    target = tmp_path / "auto.plate"
    doc = PlateDocument(path=target)
    doc.save()
    old = document_module.AUTOSAVE_DELAY_MS
    document_module.AUTOSAVE_DELAY_MS = 50
    try:
        doc.mutate("Paint Wells", paint_first_well)
        assert doc.is_dirty
        QTest.qWait(300)
        assert not doc.is_dirty
        assert loads(target.read_text(encoding="utf-8")) == doc.layout
    finally:
        document_module.AUTOSAVE_DELAY_MS = old


def test_revert_to_saved_reloads_and_clears_undo(tmp_path):
    target = tmp_path / "r.plate"
    doc = PlateDocument(path=target)
    doc.save()
    saved = doc.layout
    doc.mutate("Paint Wells", paint_first_well)
    assert doc.revert_to_saved() is True
    assert doc.layout == saved and doc.undo_stack.count() == 0 and not doc.is_dirty
