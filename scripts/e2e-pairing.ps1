# e2e-pairing.ps1 - pairing join loop without a phone. Windows only.
# Builds calcar-api plus the dev-only pcjoin prover, serves a dev-only
# in-memory backend, and runs the full Owner plus session plus PC join
# loop against it. Repeatable artifact: this script plus its log.
$ErrorActionPreference = "Stop"

$RepoRoot = (Get-Location).Path
$LogDir = Join-Path $RepoRoot "target/e2e-pairing"
$LogFile = Join-Path $LogDir "e2e-pairing.log"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
if (Test-Path $LogFile) { Remove-Item $LogFile }

function Log($msg) {
  $line = "[e2e-pairing] $msg"
  Write-Host $line
  Add-Content -Path $LogFile -Value $line
}

$failures = 0
function Check($name, $cond, $detail) {
  if ($cond) { Log "PASS $name" }
  else { Log "FAIL $name : $detail"; $script:failures++ }
}

$Port = 18080
$Base = "http://127.0.0.1:$Port"

Log "start os=$([Environment]::OSVersion.VersionString)"
Set-Location (Join-Path $RepoRoot "backend")
go build -o (Join-Path $env:TEMP "calcar-e2e-pairing-api.exe") ./cmd/calcar-api 2>&1 | Tee-Object -Append -FilePath $LogFile
if ($LASTEXITCODE -ne 0) { Log "FAIL go build api"; exit 1 }
go build -o (Join-Path $env:TEMP "calcar-pcjoin.exe") ./cmd/pcjoin 2>&1 | Tee-Object -Append -FilePath $LogFile
if ($LASTEXITCODE -ne 0) { Log "FAIL go build pcjoin"; exit 1 }

$ApiExe = Join-Path $env:TEMP "calcar-e2e-pairing-api.exe"
$JoinExe = Join-Path $env:TEMP "calcar-pcjoin.exe"
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

  $out = & $JoinExe -e2e -backend $Base -name "E2E-PC" 2>&1 | Tee-Object -Append -FilePath $LogFile
  $joined = ($out | Select-String -Pattern "pcjoin PASS").Count
  Check "join-loop-pass" ($joined -ge 1) "pass-lines=$joined"
  Check "join-landed" (($out | Select-String -Pattern "join landed").Count -ge 1) "no landing line"

  # Negative: a garbage session is refused. pcjoin exits non-zero by
  # design here, so the stop-on-error preference pauses for one call.
  $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
  $bad = & $JoinExe -session "00000000-0000-4000-8000-000000000000" -nonce "bogus" -rendezvous "$Base/v1/pairing/sessions/00000000-0000-4000-8000-000000000000/join-request" -name "E2E-PC" 2>&1 | Out-String
  $badCode = $LASTEXITCODE
  $ErrorActionPreference = $prev
  Add-Content -Path $LogFile -Value $bad
  Check "bogus-session-refused" (($badCode -ne 0) -and ($bad -match "pcjoin FAIL")) "code=$badCode"
} finally {
  if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force }
  Set-Location $RepoRoot
}

if ($failures -gt 0) { Log "FAIL total=$failures"; exit 1 }
Log "PASS total pairing loop green"
