<#
  Starts the SOLVANTA backend, loading local env first.

      Copy  .env.example  ->  .env, fill in POSTGRES_DSN, then:

          run-dev.cmd            (or .\run-dev.ps1 if your policy allows it)

  Without POSTGRES_DSN the server runs on the in-memory store: every request
  is served from RAM and all of it is gone the moment this window closes.

      run-dev.cmd -Check        load .env, report what it parsed, then exit
                                without starting the server
#>
param(
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------------------------------------------------------------------------
# 1. Local env, from two optional files. `.env` is plain dotenv (KEY=value),
#    the format most tooling expects; `.env.ps1` is a PowerShell override for
#    anything that needs more than a scalar. Both are applied to THIS
#    process's environment so the `go run` child inherits them.
# ---------------------------------------------------------------------------
$files = @()

$dotenv = Join-Path $here '.env'
if (Test-Path $dotenv) {
    # -Encoding UTF8, not the PS 5.1 default: a BOM (editors add one) would
    # otherwise prefix the first line with stray bytes and defeat the "#"
    # comment check below.
    foreach ($line in (Get-Content $dotenv -Encoding UTF8)) {
        $line = $line.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $line.Substring(0, $eq).Trim() -replace '^export\s+', ''
        # Not a plausible identifier (log noise, half-edited line): skip it
        # rather than blow up the whole startup.
        if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { continue }
        $val = $line.Substring($eq + 1).Trim().Trim([char[]]@(34, 39))
        Set-Item -Path "env:$key" -Value $val
    }
    $files += '.env'
}

$ps1 = Join-Path $here '.env.ps1'
if (Test-Path $ps1) {
    . $ps1
    $files += '.env.ps1'
}

if ($files.Count -eq 0) {
    Write-Host 'No .env found - using this script''s defaults.' -ForegroundColor Yellow
    Write-Host '  Copy .env.example to .env and set POSTGRES_DSN for persistence.'
    Write-Host ''
}

# ---------------------------------------------------------------------------
# 1b. A stable dev signing key. With SECRET unset the server mints a random
#     per-process key (see httpapi/server.go), so every restart invalidated the
#     bearer token the app had stored: writes then failed 401 while the
#     offline-first UI kept reporting success. Generate one once and keep it in
#     .env (gitignored) so tokens outlive a restart. Production still refuses
#     to boot without an explicit SECRET, so nothing here weakens that check.
# ---------------------------------------------------------------------------
if ([string]::IsNullOrEmpty($env:SECRET)) {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $env:SECRET = -join ($bytes | ForEach-Object { $_.ToString('x2') })

    # Rewrite instead of appending: Add-Content glues onto a last line that has
    # no trailing newline, and a freshly copied .env.example already carries an
    # empty "SECRET=" that must be updated in place rather than shadowed.
    $lines = @()
    $replaced = $false
    if (Test-Path $dotenv) {
        foreach ($existing in (Get-Content $dotenv -Encoding UTF8)) {
            if ($existing -match '^\s*SECRET\s*=') { $lines += "SECRET=$env:SECRET"; $replaced = $true }
            else { $lines += $existing }
        }
    }
    if (-not $replaced) { $lines += "SECRET=$env:SECRET" }
    Set-Content -Path $dotenv -Value $lines -Encoding UTF8

    Write-Host 'secret: generated a dev signing key and saved it to .env' -ForegroundColor DarkYellow
    Write-Host '        (bearer tokens now survive a backend restart)' -ForegroundColor DarkYellow
}

# ---------------------------------------------------------------------------
# 2. Locate go.exe. It is not on PATH on this machine, and a bare `go` would
#    fail with an unhelpful "not recognised".
# ---------------------------------------------------------------------------
$go = $null
$onPath = Get-Command go.exe -ErrorAction SilentlyContinue
if ($onPath) { $go = $onPath.Source }
elseif (Test-Path 'C:\Program Files\Go\bin\go.exe') { $go = 'C:\Program Files\Go\bin\go.exe' }
if (-not $go) { throw 'go.exe not found - install Go or add it to PATH.' }

# ---------------------------------------------------------------------------
# 3. Say up front which store we are on, so nobody is surprised later by
#    test data having vanished on restart.
# ---------------------------------------------------------------------------
if ($env:POSTGRES_DSN) {
    Write-Host 'store: PostgreSQL  (data persists across restarts)' -ForegroundColor Green
} else {
    Write-Host 'store: IN-MEMORY   (all data lost on restart)' -ForegroundColor Yellow
    Write-Host '         set POSTGRES_DSN in .env to persist.' -ForegroundColor DarkYellow
}
$port = if ([string]::IsNullOrEmpty($env:PORT)) { '8080' } else { $env:PORT }
Write-Host "addr:  http://127.0.0.1:$port/health"

if ($Check) {
    # The password is redacted: this output is exactly the sort of thing that
    # gets pasted into a chat or a ticket.
    $dsn = ''
    if ($env:POSTGRES_DSN) {
        $dsn = [regex]::Replace($env:POSTGRES_DSN, '://([^:/@]+):([^@]+)@', '://$1:***@')
    }
    if ($files.Count -gt 0) { Write-Host "env:   loaded from $($files -join ' + ')" }
    if ($env:SECRET) { Write-Host 'secret: set (dev key - bearer tokens survive restarts)' }
    else { Write-Host 'secret: NOT set - the server will mint a random key that changes every boot' -ForegroundColor Yellow }
    if ($dsn) { Write-Host "dsn:   $dsn" -ForegroundColor Cyan }
    else { Write-Host 'dsn:   (none set)' -ForegroundColor DarkYellow }
    Write-Host 'check only - configuration loaded, server NOT started.' -ForegroundColor Cyan
    return
}

Write-Host ''
Push-Location $here
try {
    & $go run ./cmd/server
}
finally {
    Pop-Location
}
