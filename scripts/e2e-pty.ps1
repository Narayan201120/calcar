# e2e-pty.ps1 - repeatable P4 PTY proof. Windows only. Run from repo root.
$ErrorActionPreference = "Stop"

$RepoRoot = (Get-Location).Path
$LogDir = Join-Path $RepoRoot "target/e2e-pty"
$LogFile = Join-Path $LogDir "e2e-pty.log"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
if (Test-Path $LogFile) { Remove-Item $LogFile }

function Log($msg) {
  $line = "[e2e-pty] $msg"
  Write-Host $line
  Add-Content -Path $LogFile -Value $line
}

Log "start os=$([Environment]::OSVersion.VersionString)"
Set-Location (Join-Path $RepoRoot "agent")
cargo --version | Tee-Object -Append -FilePath $LogFile
rustc --version | Tee-Object -Append -FilePath $LogFile

Log "step=unit-cargo-test"
cargo test -p calcar-pty -- --test-threads=1 --nocapture 2>&1 | Tee-Object -Append -FilePath $LogFile
if ($LASTEXITCODE -ne 0) { Log "FAIL cargo test exit=$LASTEXITCODE"; exit 1 }
Log "pass=cargo-test"

Log "step=tree-kill"
$tree = cargo test -p calcar-pty kill_ends_the_whole_tree -- --test-threads=1 --nocapture 2>&1 | Tee-Object -Append -FilePath $LogFile
if ($LASTEXITCODE -ne 0) { Log "FAIL tree kill test"; exit 1 }
Log "pass=tree-kill grandchild-reaped"

Log "step=backpressure"
$bp = cargo test -p calcar-pty large_output_arrives_complete_under_a_slow_consumer -- --test-threads=1 --nocapture 2>&1 | Tee-Object -Append -FilePath $LogFile
if ($LASTEXITCODE -ne 0) { Log "FAIL backpressure test"; exit 1 }
Log "pass=backpressure lines=2000"

Log "step=drop-no-deadlock timeout-sec=90"
$job = Start-Job -ScriptBlock { param($root) Set-Location (Join-Path $root "agent"); cargo test -p calcar-pty -- --test-threads=1 2>&1 } -ArgumentList $RepoRoot
$done = Wait-Job $job -Timeout 90
if (-not $done) {
  Stop-Job $job; Remove-Job -Force $job
  Log "FAIL drop or pump hung past 90s, suspect pump join on full channel"
  exit 1
}
Receive-Job $job | Tee-Object -Append -FilePath $LogFile
Remove-Job $job
Log "pass=no-deadlock"

Log "step=leak-sweep"
Set-Location $RepoRoot
$leaks = tasklist /NH /FO CSV | Select-String -Pattern '"ping.exe"'
if ($leaks) { Log "WARN ping stragglers remain:"; $leaks | Tee-Object -Append -FilePath $LogFile }
else { Log "pass=no-ping-stragglers" }

Log "GREEN all three properties held"
