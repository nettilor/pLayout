# Building pLayout for Windows

Everything below runs **on a Windows machine** (PyInstaller cannot cross-compile). It takes
about five minutes the first time. Nothing here needs admin rights.

## The short way: one script

Install **Python 3.12 (64-bit)** from https://www.python.org/downloads/windows/ (tick *Add
python.exe to PATH*), get the repository onto the machine, then **double-click
`python_port\packaging\build_windows.bat`**. It checks Python, creates `.venv`, installs
everything, runs the tests, builds `dist\pLayout\pLayout.exe`, zips it, and — if Inno Setup
is installed — compiles `dist\pLayout-<version>-setup.exe`. Re-run it after every update;
`build_windows.ps1 -SkipTests` is the fast rebuild, `-Clean` starts from scratch.

The sections below are the same steps by hand, for when something needs a closer look.

## 1. One-time set-up

1. Install **Python 3.12 (64-bit)** from https://www.python.org/downloads/windows/ — tick
   *Add python.exe to PATH*. (Not the Microsoft Store build, not Anaconda: PyInstaller
   bundles are cleanest from the python.org interpreter.)
2. Get the repository onto the machine (git clone, or unzip a download of it).
3. Open **PowerShell** in the repository's `python_port` folder and create the environment:

   ```powershell
   py -3.12 -m venv .venv
   .venv\Scripts\Activate.ps1
   python -m pip install --upgrade pip
   pip install -e ".[dev,build]"
   ```

   If PowerShell refuses to run `Activate.ps1`, run once:
   `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` and try again — or use
   `cmd.exe` and `.venv\Scripts\activate.bat`.

4. Sanity check before building — the app runs from source and the tests pass:

   ```powershell
   python -m playout                # the window opens; close it again
   python -m pytest -q              # expect all green
   ```

## 2. Build the executable

```powershell
pyinstaller packaging\playout.spec --noconfirm
```

Output: **`dist\pLayout\`** — a folder holding `pLayout.exe` and an `_internal\` directory.
The folder is the application; it must be kept together. Double-click `pLayout.exe` to run
it; `pLayout.exe some.plate` opens a file.

Why a folder and not a single `.exe`: a one-file build unpacks itself to a temp folder on
every launch (slow start) and is far more often flagged by antivirus heuristics.

## 3. Distribute

**Simplest**: zip the `dist\pLayout` folder (right-click → *Compress to ZIP file*) and share
`pLayout-<version>-windows.zip`. Recipients unzip anywhere (e.g. `Documents\pLayout`) and run
`pLayout.exe`; a shortcut on the desktop or taskbar is a right-click away.

**With an installer** (adds Start-menu entry, uninstaller, `.plate` double-click):
install [Inno Setup](https://jrsoftware.org/isinfo.php), open `packaging\inno.iss`, and
press *Compile* → `dist\pLayout-<version>-setup.exe`. The installer is per-user (no admin
prompt) and registers the `.plate` file type so double-clicking a layout opens pLayout.

## 4. What Windows will say the first time

An unsigned executable triggers **SmartScreen** ("Windows protected your PC") on first
launch: click *More info* → *Run anyway*. This is the Windows equivalent of the Mac's
"Open Anyway" and is asked once per machine. Code signing (a paid certificate) removes it;
until then, say so in the release notes.

If a corporate antivirus quarantines `pLayout.exe`, the folder build above is already the
least-suspicious shape; whitelisting the folder is the remaining option.

## 5. Where things live on Windows

- Settings: `%APPDATA%\nettilor\pLayout.ini`
- Layout templates: `%APPDATA%\nettilor\pLayout\Templates\*.plate`
- Crash log (only if something goes badly wrong): `%APPDATA%\nettilor\pLayout\pLayout-crash.log`

## 6. Smoke checklist after a build

- [ ] `pLayout.exe` opens with an empty 96-well plate.
- [ ] Open a `.plate` file written by the Mac app — it shows painted; edit, wait 2 s
      (autosave), open it again on the Mac.
- [ ] Paint, undo, Series Fill, XY Fill, Save State / revert.
- [ ] Export Excel → opens in Excel with coloured maps, Wells, Legend.
- [ ] Export PNG / PDF, Print to PDF.
- [ ] Preferences: change the plate font, the empty-well colour; restart — remembered.

## 7. Troubleshooting

- **`ImportError: DLL load failed while importing QtCore: The specified procedure could not
  be found`** (seen while the tests start): PySide6 is installed but its Qt DLLs cannot bind.
  The script now catches this, retries with the PySide6 **6.8 LTS** wheels, and if that still
  fails tells you what to do — normally installing the *Microsoft Visual C++ Redistributable
  2015-2022 (x64)* (https://aka.ms/vs/17/release/vc_redist.x64.exe) and running Windows
  Update, or removing another program's older `Qt6Core.dll` folder from `PATH`
  (`where.exe Qt6Core.dll` shows every copy Windows would find).
- **`unexpected token '}'`** from PowerShell: the `.ps1` was saved without its UTF-8 BOM by
  a transfer tool; re-copy it from the repository (it is ASCII + BOM on purpose).
- **Copying `python_port` from the Mac by hand**: leave the Mac's `.venv/`, `build/` and
  `dist/` behind (they are ignored by git anyway); the script creates its own `.venv`.

## 8. Updating the build

Pull the new source, then in the activated venv:

```powershell
pip install -e ".[dev,build]"     # only if dependencies changed
pyinstaller packaging\playout.spec --noconfirm
```

Bump the version in `pyproject.toml` / `playout/__init__.py` (and `MyAppVersion` in
`packaging\inno.iss`) before a release build.
