# e2e-revoke.ps1 - revocation loop without a phone. Windows only.
# Builds calcar-api plus the dev-only revoke-e2e prover, serves a dev-only
# in-memory backend on a fresh port, and runs the full Owner plus session
# plus PC join plus approve plus revoke loop against it. Repeatable
# artifact: this script plus its log.
$ErrorActionPreference = "Stop"

$RepoRoot = (Get-Location).Path
$LogDir = Join-Path $RepoRoot "target/e2e-revoke"
$LogFile = Join-Path $LogDir "e2e-revoke.log"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
if (Test-Path $LogFile) { Remove-Item $LogFile }

function Log($msg) {
  $line = "[e2e-revoke] $msg"
  Write-Host $line
  Add-Content -Path $LogFile -Value $line
}

$failures = 0
function Check($name, $cond, $detail) {
  if ($cond) { Log "PASS $name" }
  else { Log "FAIL $name : $detail"; $script:failures++ }
}

$Port = 18081
$Base = "http://127.0.0.1:$Port"

Log "start os=$([Environment]::OSVersion.VersionString)"
Set-Location (Join-Path $RepoRoot "backend")
go build -o (Join-Path $env:TEMP "calcar-e2e-revoke-api.exe") ./cmd/calcar-api 2>&1 | Tee-Object -Append -FilePath $LogFile
if ($LASTEXITCODE -ne 0) { Log "FAIL go build api"; exit 1 }
go build -o (Join-Path $env:TEMP "calcar-revoke-e2e.exe") ./cmd/revoke-e2e 2>&1 | Tee-Object -Append -FilePath $LogFile
if ($LASTEXITCODE -ne 0) { Log "FAIL go build revoke-e2e"; exit 1 }

$ApiExe = Join-Path $env:TEMP "calcar-e2e-revoke-api.exe"
$ProverExe = Join-Path $env:TEMP "calcar-revoke-e2e.exe"
$env:PORT = "$Port"
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

  $out = & $ProverExe -backend $Base -name "E2E-PC-REVOKE" 2>&1 | Tee-Object -Append -FilePath $LogFile
  $passes = ($out | Select-String -Pattern "revoke PASS").Count
  Check "revoke-loop-pass" ($passes -ge 10) "pass-lines=$passes"
  Check "join-landed" (($out | Select-String -Pattern "join landed").Count -ge 1) "no join line"
  Check "approve-ok" (($out | Select-String -Pattern "approve ok").Count -ge 1) "no approve line"
  Check "revoke-ok" (($out | Select-String -Pattern "revoke ok").Count -ge 1) "no revoke line"
  Check "online-propagation" (($out | Select-String -Pattern "online propagation").Count -ge 1) "no trust.revoked line"
  Check "heartbeat-rejected" (($out | Select-String -Pattern "heartbeat rejected").Count -ge 1) "no heartbeat line"
  Check "devices-rejected" (($out | Select-String -Pattern "devices rejected").Count -ge 1) "no devices line"
  Check "decision-rejected" (($out | Select-String -Pattern "decision rejected").Count -ge 1) "no decision line"
  Check "verify-refused" (($out | Select-String -Pattern "verify refused").Count -ge 1) "no verify line"
  Check "reconnect-refused" (($out | Select-String -Pattern "reconnect refused").Count -ge 1) "no reconnect line"

  # Negative: an unauthenticated revoke is refused. curl exits 0 here,
  # so assert on the status code, not the exit code.
  $code = curl.exe -s -o NUL -w '%{http_code}' -X POST "$Base/v1/devices/NOPE/revoke" -H "Content-Type: application/json" -d '{}'
  Add-Content -Path $LogFile -Value "[e2e-revoke] unauth revoke status=$code"
  Check "unauth-revoke-refused" ($code -eq "401") "status=$code"
} finally {
  if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force }
  Set-Location $RepoRoot
}

if ($failures -gt 0) { Log "FAIL total=$failures"; exit 1 }
Log "PASS total revoke loop green"
