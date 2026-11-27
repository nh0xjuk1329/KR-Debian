param([ValidateSet('start','stop')][string]$Action = 'start')
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot/../..").Path
Set-Location -LiteralPath $repo
function Install-PackageId([string]$Id, [string[]]$Extra) {
    & winget install --exact --id $Id --accept-source-agreements --accept-package-agreements @Extra
    if ($LASTEXITCODE -ne 0) { throw "Installation of $Id failed ($LASTEXITCODE)." }
}
function Find-Python {
    $paths = @((Get-Command python.exe -ErrorAction SilentlyContinue).Source)
    $paths += @(Get-ChildItem "$env:LOCALAPPDATA/Programs/Python/Python*/python.exe","$env:ProgramFiles/Python*/python.exe" -ErrorAction SilentlyContinue | ForEach-Object FullName)
    foreach ($path in $paths) {
        if (!$path -or $path -like '*\Microsoft\WindowsApps\*') { continue }
        & $path -c 'import sys; sys.exit(sys.version_info < (3,11))'
        if (!$LASTEXITCODE) { return $path }
    }
}
$python = Find-Python
if (!$python) {
    Install-PackageId Python.Python.3.13
    $python = Find-Python
    if (!$python) { throw 'Python 3.11 or newer could not be located after installation.' }
}
if ($Action -eq 'stop') { & $python "$PSScriptRoot/host.py" stop; exit $LASTEXITCODE }
$vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
function Find-Compiler {
    if (Test-Path $vswhere) {
        & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 Microsoft.VisualStudio.Component.VC.CMake.Project -property installationPath
    }
}
$vs = Find-Compiler
if (!$vs) {
    Install-PackageId Microsoft.VisualStudio.2022.BuildTools @('--override','--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended')
    $vs = Find-Compiler
    if (!$vs) { throw 'Visual Studio C++ tools and CMake could not be located.' }
}
$tools = Join-Path $vs 'Common7/IDE/CommonExtensions/Microsoft/CMake'
$env:Path = "$tools/CMake/bin;$tools/Ninja;$env:USERPROFILE/.cargo/bin;$env:ProgramFiles/Git/cmd;$env:Path"
if (!(Get-Command git -ErrorAction SilentlyContinue)) { Install-PackageId Git.Git }
if (!(Get-Command rustup -ErrorAction SilentlyContinue)) {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid())
    New-Item -ItemType Directory -Path $temp | Out-Null
    $installer = Join-Path $temp 'rustup-init.exe'
    try {
        $uri = 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe'
        & curl.exe -fsSL --retry 3 $uri -o $installer
        if ($LASTEXITCODE) { throw 'Rust bootstrap download failed.' }
        $digest = (& curl.exe -fsSL "$uri.sha256").Trim().Split(' ')[0]
        if ((Get-FileHash $installer).Hash -ne $digest) { throw 'Rust bootstrap checksum failed.' }
        & $installer -y --profile minimal --no-modify-path --default-toolchain 1.99.0
        if ($LASTEXITCODE) { throw 'Rust installation failed.' }
    } finally {
        if (Test-Path -LiteralPath $installer) { Remove-Item -LiteralPath $installer }
        Remove-Item -LiteralPath $temp
    }
}
$toolchains = & rustup toolchain list
if (!($toolchains -match '^1\.99\.0-x86_64-pc-windows-msvc(\s|$)')) {
    & rustup toolchain install 1.99.0 --profile minimal
    if ($LASTEXITCODE) { throw 'Rust 1.99 installation failed.' }
}
& cargo +1.99.0 build --locked --release
if ($LASTEXITCODE) { throw 'The native Windows server build failed.' }
Add-Type -Path (Join-Path $repo 'server/scripts/local/LocalServerLifetime.cs')
[LocalServerLifetime]::Enable()
. (Join-Path $repo 'server/scripts/local/import_local_env.ps1')
Import-LocalEnv -Path (Join-Path $repo '.env')
& $python -u "$PSScriptRoot/host.py"
exit $LASTEXITCODE
