param(
    [ValidateSet('Test', 'Smoke', 'Play', 'Editor', 'Import')]
    [string]$Action = 'Test',
    [string]$GodotPath = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $root 'game'
$version = (Get-Content -LiteralPath (Join-Path $project '.godot-version') -Raw).Trim()

if ([string]::IsNullOrWhiteSpace($GodotPath)) {
    $GodotPath = Join-Path $root ".tools/godot-$version/Godot_v$version-stable_win64_console.exe"
}
if (-not (Test-Path -LiteralPath $GodotPath -PathType Leaf)) {
    throw "Godot $version is required. Download the standard Windows build from https://godotengine.org/download/archive/ and pass -GodotPath or extract it under .tools/godot-$version/."
}
$GodotPath = (Resolve-Path -LiteralPath $GodotPath).Path
$actualVersion = (& $GodotPath --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $actualVersion.StartsWith("$version.stable.")) {
    throw "Expected Godot $version stable; received: $actualVersion"
}

function Invoke-GodotCheck {
    param([string[]]$Arguments, [string]$SuccessPattern = '')
    $output = & $GodotPath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = $output -join "`n"
    $output | ForEach-Object { Write-Output $_ }
    if ($exitCode -ne 0 -or $text -match '(SCRIPT ERROR|ERROR):') {
        throw "Godot check failed (exit $exitCode)."
    }
    if ($SuccessPattern -and $text -notmatch $SuccessPattern) {
        throw 'Godot exited without the expected completion marker.'
    }
}

if ($Action -eq 'Test') {
    Invoke-GodotCheck -Arguments @('--headless', '--path', $project, '--script', 'res://tests/run_tests.gd') -SuccessPattern 'Factory tests: \d+ checks, 0 failures'
    return
}

Invoke-GodotCheck -Arguments @('--headless', '--editor', '--import', '--path', $project)
if ($Action -eq 'Import') {
    return
}
if ($Action -eq 'Smoke') {
    Invoke-GodotCheck -Arguments @('--path', $project, '--script', 'res://tests/ui_smoke.gd') -SuccessPattern 'Factory UI smoke: \d+ checks, 0 failures'
    return
}

$launchArguments = @('--path', ('"{0}"' -f $project))
if ($Action -eq 'Editor') {
    $launchArguments += '--editor'
}
$windowedPath = $GodotPath -replace '_console\.exe$', '.exe'
if (-not (Test-Path -LiteralPath $windowedPath -PathType Leaf)) {
    $windowedPath = $GodotPath
}
$process = Start-Process -FilePath $windowedPath -ArgumentList $launchArguments -PassThru
Write-Output "Started Godot $Action (PID $($process.Id))."