# pLayout — Python/PySide6 port

A local desktop version of pLayout for Windows (and anywhere Qt runs), built alongside the
native macOS app in this repository. It reads and writes the same `.plate` files and produces
the same exports. Functional parity with the Mac app is the goal; the visual polish is not
(see `PARITY.md` for the row-by-row status, `PORT.md` for everything else).

## Run from source

```sh
cd python_port
python3 -m venv .venv
.venv/bin/pip install -e ".[dev]"        # Windows: .venv\Scripts\pip install -e ".[dev]"
.venv/bin/python -m playout [file.plate]
```

Requires Python 3.11+. Dependencies: PySide6 (Qt 6), openpyxl.

## Tests

```sh
.venv/bin/pytest -q
```

Everything runs headless (`QT_QPA_PLATFORM=offscreen`). `tests/fixtures/` holds real
`.plate` files written by the Mac app; the port must open every one of them and re-save it
without changing its meaning.

## Build a Windows executable

Install python.org Python 3.12 (64-bit) and **double-click `packaging\build_windows.bat`** —
it checks, installs, tests, builds and zips. See **`packaging/build_windows.md`** for the
details and the manual equivalent:

```powershell
py -3.12 -m venv .venv
.venv\Scripts\Activate.ps1
pip install -e ".[dev,build]"
pyinstaller packaging\playout.spec --noconfirm
```

The result is the folder `dist\pLayout\` (run `pLayout.exe`); zip it to distribute, or compile
`packaging\inno.iss` with Inno Setup for an installer that also registers `.plate` files.
Unsigned builds get the SmartScreen prompt on first launch (*More info → Run anyway*).

## Licence

Same as the Mac app: PolyForm Noncommercial 1.0.0 (see `../LICENSE`).
