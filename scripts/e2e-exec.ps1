# e2e-exec.ps1 - repeatable P4 plain-pipe plus workflow proof. Windows only.
$ErrorActionPreference = "Stop"

$RepoRoot = (Get-Location).Path
$LogDir = Join-Path $RepoRoot "target/e2e-exec"
$LogFile = Join-Path $LogDir "e2e-exec.log"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
if (Test-Path $LogFile) { Remove-Item $LogFile }

function Log($msg) {
  $line = "[e2e-exec] $msg"
  Write-Host $line
  Add-Content -Path $LogFile -Value $line
}

Log "start os=$([Environment]::OSVersion.VersionString)"
Set-Location (Join-Path $RepoRoot "agent")

Log "step=exec-runner timeout-sec=240"
$job = Start-Job -ScriptBlock {
  param($root) Set-Location (Join-Path $root "agent")
  cargo run -p calcar-agent --example e2e_exec 2>&1
} -ArgumentList $RepoRoot
$done = Wait-Job $job -Timeout 240
if (-not $done) {
  Stop-Job $job; Remove-Job -Force $job
  Set-Location $RepoRoot
  Log "FAIL runner hung past 240s"
  exit 1
}
$out = Receive-Job $job
Remove-Job $job
$out | Tee-Object -Append -FilePath $LogFile
if (!($out -match "E2E-EXEC GREEN")) {
  Set-Location $RepoRoot
  Log "FAIL runner did not report GREEN"
  exit 1
}
Log "pass=e2e-exec"

Log "step=leak-sweep"
Set-Location $RepoRoot
$leaks = tasklist /NH /FO CSV | Select-String -Pattern '"ping.exe"'
if ($leaks) { Log "WARN ping stragglers remain:"; $leaks | Tee-Object -Append -FilePath $LogFile }
else { Log "pass=no-ping-stragglers" }

Log "GREEN plain pipes plus workflow plus session plus router held"
