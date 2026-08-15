<#
.SYNOPSIS
    Builds pLayout for Windows in one go: checks Python, creates the virtual environment,
    installs dependencies, runs the tests, runs PyInstaller, zips the result, and compiles
    the installer when Inno Setup is installed.

.USAGE
    Double-click build_windows.bat, or from PowerShell in the python_port folder:
        .\packaging\build_windows.ps1
        .\packaging\build_windows.ps1 -SkipTests      # faster rebuild
        .\packaging\build_windows.ps1 -Clean          # wipe build/ dist/ first
#>
param(
    [switch]$SkipTests,
    [switch]$Clean
)

# "Continue" on purpose: native tools (pip, pytest, PyInstaller) write progress to stderr,
# which Windows PowerShell 5.1 turns into terminating errors under "Stop". Every native
# call below checks $LASTEXITCODE itself instead.
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)   # python_port/
Set-Location $root

function Step($text) { Write-Host ""; Write-Host "==> $text" -ForegroundColor Cyan }
function Fail($text) { Write-Host ""; Write-Host "ERROR: $text" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- 1. Python 3.11+ (64-bit)
Step "Checking for Python"
function Invoke-Py {
    # Runs a candidate interpreter ("py -3.12" or "python") with the given arguments.
    param([string]$Candidate, [string[]]$Arguments)
    $parts = $Candidate -split " "
    $exe = $parts[0]
    $pre = @()
    if ($parts.Length -gt 1) { $pre = $parts[1..($parts.Length - 1)] }
    & $exe @pre @Arguments
}
$python = $null
$saved = $ErrorActionPreference
$ErrorActionPreference = "SilentlyContinue"     # probing interpreters that may not exist
$LASTEXITCODE = 0
foreach ($candidate in @("py -3.12", "py -3.13", "py -3.11", "python")) {
    $out = Invoke-Py $candidate @("-c", "import sys; print(sys.version_info[0], sys.version_info[1], sys.maxsize > 2**32)") 2>&1
    if ($LASTEXITCODE -eq 0 -and $out) {
        $line = ($out | Select-Object -Last 1).ToString().Trim()
        $v = $line -split " "
        if ($v.Length -ge 3 -and $v[0] -eq "3" -and [int]$v[1] -ge 11 -and $v[2] -eq "True") { $python = $candidate; break }
    }
}
$ErrorActionPreference = $saved
if (-not $python) {
    Fail "No 64-bit Python 3.11+ found. Install Python 3.12 (64-bit) from https://www.python.org/downloads/windows/ and tick 'Add python.exe to PATH', then run this again."
}
Write-Host "    using: $python"

# ---------------------------------------------------------------- 2. virtual environment
if ($Clean) {
    Step "Cleaning build/ and dist/"
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue build, dist
}
$venvPython = Join-Path $root ".venv\Scripts\python.exe"
if (-not (Test-Path $venvPython)) {
    Step "Creating the virtual environment (.venv)"
    Invoke-Py $python @("-m", "venv", ".venv")
    if ($LASTEXITCODE -ne 0) { Fail "Could not create the virtual environment." }
} else {
    Write-Host "    .venv already exists"
}

Step "Installing pLayout and its dependencies into .venv"
& $venvPython -m pip install --upgrade pip --quiet
& $venvPython -m pip install -e ".[dev,build]" --quiet
if ($LASTEXITCODE -ne 0) { Fail "pip install failed (see above)." }
& $venvPython -c "import PySide6, openpyxl, PyInstaller; print('    PySide6', PySide6.__version__, '| openpyxl', openpyxl.__version__, '| PyInstaller', PyInstaller.__version__)"
if ($LASTEXITCODE -ne 0) { Fail "The dependencies did not import - the install is incomplete." }

# ---------------------------------------------------------------- 2b. can Qt actually load?
# "DLL load failed while importing QtCore: The specified procedure could not be found" means
# the Qt DLLs are present but cannot bind - an old Visual C++ runtime, or another program's
# older Qt6Core.dll found first on PATH. Detect it now, with a clear way out.
Step "Checking that Qt loads"
$qtCheck = "from PySide6 import QtCore, QtGui, QtWidgets, QtPrintSupport; print('    Qt', QtCore.qVersion())"
& $venvPython -c $qtCheck
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "    PySide6 installed but Qt would not load. Trying the 6.8 LTS build of PySide6..." -ForegroundColor Yellow
    & $venvPython -m pip install --quiet --force-reinstall "PySide6-Essentials==6.8.*" "shiboken6==6.8.*"
    & $venvPython -c $qtCheck
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "    Other Qt6Core.dll files on PATH (an older one found first breaks the load):" -ForegroundColor Yellow
        & where.exe Qt6Core.dll 2>$null
        Fail ("Qt still cannot load. Two things to try, then run this script again:`n" +
              "      1. Install the Microsoft Visual C++ Redistributable 2015-2022 (x64):`n" +
              "         https://aka.ms/vs/17/release/vc_redist.x64.exe`n" +
              "         and make sure Windows Update is current (PySide6 needs Windows 10 21H2 or later).`n" +
              "      2. If 'where.exe' listed a Qt6Core.dll from another program above, that program's folder is`n" +
              "         on PATH ahead of ours; remove it from PATH (or run this script from a fresh cmd window`n" +
              "         where that program has not been started).")
    }
    Write-Host "    PySide6 6.8 works on this machine - keeping it." -ForegroundColor Green
}

# ---------------------------------------------------------------- 3. tests
if (-not $SkipTests) {
    Step "Running the test suite (headless)"
    $env:QT_QPA_PLATFORM = "offscreen"
    & $venvPython -m pytest -q
    if ($LASTEXITCODE -ne 0) { Fail "Tests failed - not building a broken app. Fix the failures (or rerun with -SkipTests if you know what you are doing)." }
    Remove-Item Env:QT_QPA_PLATFORM -ErrorAction SilentlyContinue
} else {
    Write-Host "    tests skipped (-SkipTests)"
}

# ---------------------------------------------------------------- 4. build
Step "Building dist\pLayout with PyInstaller"
& $venvPython -m PyInstaller packaging\playout.spec --noconfirm --workpath build\pyinstaller --distpath dist
if ($LASTEXITCODE -ne 0) { Fail "PyInstaller failed (see above)." }
$exe = Join-Path $root "dist\pLayout\pLayout.exe"
if (-not (Test-Path $exe)) { Fail "PyInstaller finished but $exe is missing." }

# ---------------------------------------------------------------- 5. version + zip
$version = & $venvPython -c "import playout; print(playout.__version__)"
$zip = Join-Path $root "dist\pLayout-$version-windows.zip"
Step "Zipping dist\pLayout -> $(Split-Path -Leaf $zip)"
if (Test-Path $zip) { Remove-Item $zip }
try {
    Compress-Archive -Path (Join-Path $root "dist\pLayout") -DestinationPath $zip -ErrorAction Stop
} catch {
    Write-Host "    zip failed: $_ (the dist\pLayout folder is still complete)" -ForegroundColor Yellow
    $zip = "(not created)"
}

# ---------------------------------------------------------------- 6. installer (optional)
$iscc = $null
foreach ($p in @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe")) {
    if ($p -and (Test-Path $p)) { $iscc = $p; break }
}
if ($iscc) {
    Step "Compiling the installer with Inno Setup"
    & $iscc "/DMyAppVersion=$version" (Join-Path $root "packaging\inno.iss")
    if ($LASTEXITCODE -ne 0) { Write-Host "    installer failed (the zip is still fine)" -ForegroundColor Yellow }
} else {
    Write-Host ""
    Write-Host "    (Inno Setup not found - skipping the installer. Install it from https://jrsoftware.org/isinfo.php to get a setup.exe with the .plate association.)" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- done
Step "Done"
Write-Host "    App folder : $exe"
Write-Host "    Zip        : $zip"
if ($iscc) { Write-Host "    Installer  : dist\pLayout-$version-setup.exe" }
Write-Host ""
Write-Host "    First launch on a new PC shows SmartScreen: 'More info' -> 'Run anyway'."
Write-Host ""
