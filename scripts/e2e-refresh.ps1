# e2e-refresh.ps1 - token rotation loop without a phone. Windows only.
# Builds calcar-api plus the dev-only pcjoin prover, serves a dev-only
# in-memory backend on a fresh port, and runs the full bootstrap plus
# login plus double-rotation loop against it. Repeatable artifact: this
# script plus its log.
$ErrorActionPreference = "Stop"

$RepoRoot = (Get-Location).Path
$LogDir = Join-Path $RepoRoot "target/e2e-refresh"
$LogFile = Join-Path $LogDir "e2e-refresh.log"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
if (Test-Path $LogFile) { Remove-Item $LogFile }

function Log($msg) {
  $line = "[e2e-refresh] $msg"
  Write-Host $line
  Add-Content -Path $LogFile -Value $line
}

$failures = 0
function Check($name, $cond, $detail) {
  if ($cond) { Log "PASS $name" }
  else { Log "FAIL $name : $detail"; $script:failures++ }
}

$Port = 18082
$Base = "http://127.0.0.1:$Port"

Log "start os=$([Environment]::OSVersion.VersionString)"
Set-Location (Join-Path $RepoRoot "backend")
go build -o (Join-Path $env:TEMP "calcar-e2e-refresh-api.exe") ./cmd/calcar-api 2>&1 | Tee-Object -Append -FilePath $LogFile
if ($LASTEXITCODE -ne 0) { Log "FAIL go build api"; exit 1 }
go build -o (Join-Path $env:TEMP "calcar-pcjoin-refresh.exe") ./cmd/pcjoin 2>&1 | Tee-Object -Append -FilePath $LogFile
if ($LASTEXITCODE -ne 0) { Log "FAIL go build pcjoin"; exit 1 }

$ApiExe = Join-Path $env:TEMP "calcar-e2e-refresh-api.exe"
$JoinExe = Join-Path $env:TEMP "calcar-pcjoin-refresh.exe"
$env:PORT = "$Port"
$env:TOKEN_TTL = "2s"
$server = Start-Process -FilePath $ApiExe -WindowStyle Hidden -PassThru
try {
  $ready = $false
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 500
    if ($server.HasExited) { Log "FAIL server exited at boot"; exit 1 }
    try {
      $code = curl.exe -s -o NUL -w '%{http_code}' "$Base/healthz"
      if ($code -eq "200") { $ready = $true; break }
    } catch { }
  }
  Check "server-ready" $ready "backend never answered /healthz"

  $out = & $JoinExe --refresh-e2e -backend $Base 2>&1 | Tee-Object -Append -FilePath $LogFile
  $passes = ($out | Select-String -Pattern "refresh PASS").Count
  Check "refresh-loop-pass" ($passes -ge 10) "pass-lines=$passes"
  Check "bootstrap-ok" (($out | Select-String -Pattern "bootstrap ok").Count -ge 1) "no bootstrap line"
  Check "login-ok" (($out | Select-String -Pattern "login ok").Count -ge 1) "no login line"
  Check "first-rotation" (($out | Select-String -Pattern "first rotation ok").Count -ge 1) "no first rotation line"
  Check "first-reuse-revoked" (($out | Select-String -Pattern "first reuse rejected").Count -ge 1) "no first reuse line"
  Check "second-rotation" (($out | Select-String -Pattern "second rotation ok").Count -ge 1) "no second rotation line"
  Check "second-reuse-revoked" (($out | Select-String -Pattern "second reuse rejected").Count -ge 1) "no second reuse line"
  Check "dead-restore" (($out | Select-String -Pattern "dead access plus live refresh restores").Count -ge 1) "no dead restore line"
  Check "expired-restore" (($out | Select-String -Pattern "expired access plus live refresh restores").Count -ge 1) "no expired restore line"
  Check "garbage-refused" (($out | Select-String -Pattern "garbage refresh refused").Count -ge 1) "no garbage line"

  # Negative: a garbage refresh is refused at the HTTP layer too.
  # curl exits 0 here, so assert on the status code, not the exit code.
  # NOTE: JSON goes via a temp file so Windows PowerShell 5.1 does not
  # strip the inner double quotes (native arg passing quirk).
  $rid = [guid]::NewGuid().ToString()
  $garbageBody = '{"device_id":"PH-NOPE","refresh_token":"garbage-refresh-xyz"}'
  $garbageFile = Join-Path $env:TEMP ("calcar-refresh-garbage-" + [guid]::NewGuid().ToString() + ".json")
  Set-Content -Path $garbageFile -Value $garbageBody -NoNewline
  $code = curl.exe -s -o NUL -w '%{http_code}' -X POST "$Base/v1/auth/refresh" -H "Content-Type: application/json" -H "X-Request-ID: $rid" -d "@$garbageFile"
  Remove-Item $garbageFile -ErrorAction SilentlyContinue
  Add-Content -Path $LogFile -Value "[e2e-refresh] garbage refresh status=$code"
  Check "garbage-refresh-refused" (($code -eq "401") -or ($code -eq "404")) "status=$code"
} finally {
  if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force }
  Set-Location $RepoRoot
}

if ($failures -gt 0) { Log "FAIL total=$failures"; exit 1 }
Log "PASS total refresh loop green"
