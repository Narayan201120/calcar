# e2e-resume.ps1 - agent restart with resume and replay. Windows only.
# A workflow runs while the agent process is killed mid-run (TerminateProcess,
# the local equivalent of kill -9). The agent restarts against the same store
# files and must reattach the same session: prior non-terminal state kept,
# missed events replayed from the ring, no duplicated completions, the ring
# monotonic across the kill, and a duplicate input UUID from before the kill
# still dedupes after. Repeatable artifact: this script plus its console log.
$ErrorActionPreference = "Stop"

$RepoRoot = (Get-Location).Path
$LogDir = Join-Path $RepoRoot "target/e2e-resume"
$LogFile = Join-Path $LogDir "e2e-resume.log"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
if (Test-Path $LogFile) { Remove-Item $LogFile }

function Log($msg) {
  $line = "[e2e-resume] $msg"
  Write-Host $line
  Add-Content -Path $LogFile -Value $line
}

$failures = 0
function Check($name, $cond, $detail) {
  if ($cond) { Log "PASS $name" }
  else { Log "FAIL $name : $detail"; $script:failures++ }
}

$T = Join-Path $env:TEMP "calcar-e2e-resume"
New-Item -ItemType Directory -Force -Path $T | Out-Null
$Port = 18424
$Base = "http://127.0.0.1:$Port"
$Token = "resume-token-abc"
$H = "Authorization: Bearer $Token"

function Get-Snap($workflow) {
  return curl.exe -s -H $H "$Base/v1/agent/computers/pc-resume/workflows/$workflow" | ConvertFrom-Json
}

function Post-Input($workflow, $id, $body) {
  Set-Content (Join-Path $T "$id.json") -NoNewline -Value (@{input_id = $id; body = $body; destructive = $false} | ConvertTo-Json -Compress)
  return curl.exe -s -X POST -H $H -H "X-Request-ID: $id" -H 'Content-Type: application/json' --data-binary "@$T\$id.json" "$Base/v1/agent/workflows/$workflow/inputs" | ConvertFrom-Json
}

Log "start os=$([Environment]::OSVersion.VersionString)"
Set-Location (Join-Path $RepoRoot "agent")
$prevEA = $ErrorActionPreference
$ErrorActionPreference = "Continue"
cargo build -p calcar-connect 2>&1 | Select-Object -Last 1 | Tee-Object -Append -FilePath $LogFile
$buildCode = $LASTEXITCODE
$ErrorActionPreference = $prevEA
if ($buildCode -ne 0) { Log "FAIL cargo build"; exit 1 }

Set-Content (Join-Path $T "token.txt") -NoNewline -Value $Token
Set-Content (Join-Path $T "agent.conf") -Value @(
  "port=$Port",
  "token_file=$T\token.txt",
  "db_path=$T\agent.db",
  "computer_id=pc-resume",
  "display_name=ResumePC",
  "owner_device_id=PH-owner",
  "exec_timeout_secs=90"
)
# Stale files from a prior run would fork the ring, so clear every store
# sidecar before seeding. Same files are reused across the kill below.
Remove-Item (Join-Path $T "agent.db") -ErrorAction SilentlyContinue
Remove-Item (Join-Path $T "agent.db-wal") -ErrorAction SilentlyContinue
Remove-Item (Join-Path $T "agent.db-shm") -ErrorAction SilentlyContinue
Remove-Item (Join-Path $T "agent.db-journal") -ErrorAction SilentlyContinue
Remove-Item (Join-Path $T "tails") -Recurse -ErrorAction SilentlyContinue
Remove-Item (Join-Path $T "calcar-connect-known.json") -ErrorAction SilentlyContinue

$server = Start-Process -FilePath (Join-Path $RepoRoot "agent\target\debug\calcar-connect.exe") -ArgumentList "--config", (Join-Path $T "agent.conf") -WindowStyle Hidden -PassThru
try {
  Start-Sleep -Seconds 2
  if ($server.HasExited) { Log "FAIL server exited at boot"; exit 1 }

  # Warm-up on a store route migrates SQLite, then seed one running generic
  # workflow with a provider session binding, like the production paths do.
  $w = curl.exe -s -o NUL -w '%{http_code}' -H "Authorization: Bearer $Token" "$Base/v1/agent/computers/pc-resume/workflows/wf-resume"
  Check "warmup" ($w -eq "404") "warm=$w"
  & 'C:\Program Files\Python312\python.exe' -c "import sqlite3,time; now=int(time.time()*1000); c=sqlite3.connect(r'$T\agent.db'); c.execute('INSERT INTO workflows VALUES (?,?,?,?,?,?,?)',('wf-resume',4,1,'Resume flow','ps-resume',now,now)); c.execute('INSERT INTO session_bindings VALUES (?,?,?,?)',('wf-resume','ps-resume','ptr-r0',now)); c.commit(); print('seeded', c.total_changes)" | Tee-Object -Append -FilePath $LogFile

  # Phase 1, before the kill: one input delivered on the running workflow.
  $d1 = Post-Input "wf-resume" "r1" "echo RESUME_ONE"
  Check "phase1-delivered" ($d1.outcome -eq "delivered" -and $d1.exit_code -eq 0) "r1=$($d1 | ConvertTo-Json -Compress)"
  $s0 = Get-Snap "wf-resume"
  Check "prekill-nonterminal" ($s0.status -ne "completed" -and $s0.status -eq "running") "status=$($s0.status)"
  $seq0 = [int]$s0.last_seq_no
  $ids0 = @($s0.activity | ForEach-Object { $_.event_id })
  $c1pre = @($s0.activity | Where-Object { $_.summary -like "*input r1 completed*" }).Count
  Check "prekill-ring" ($seq0 -ge 2 -and $c1pre -eq 1) "seq=$seq0 r1completedx$c1pre"
  Log "prekill-tail seq=$seq0 ids=$($ids0 -join ',')"
  $tailPre = Get-Content (Join-Path $T "tails\wf-resume-r1.log") -Raw -ErrorAction SilentlyContinue
  Check "tail-bytes-prekill" ($tailPre -match "RESUME_ONE") "tail=$tailPre"

  # Phase 2, kill -9 mid-run: a long command starts, then the process is
  # terminated with no graceful shutdown while the workflow is active.
  Set-Content (Join-Path $T "r-long.json") -NoNewline -Value '{"input_id":"r-long","body":"ping -n 20 127.0.0.1","destructive":false}'
  $long = Start-Job -ScriptBlock {
    param($Base, $H, $T)
    curl.exe -s -X POST -H $H -H 'X-Request-ID: r-long' -H 'Content-Type: application/json' --data-binary "@$T\r-long.json" "$Base/v1/agent/workflows/wf-resume/inputs"
  } -ArgumentList $Base, $H, $T
  Start-Sleep -Seconds 5
  Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 3
  $server.Refresh()
  Check "kill-exited" ($server.HasExited) "HasExited=$($server.HasExited)"
  Log "agent killed mid-run, same store files kept"
  Wait-Job $long -Timeout 30 | Out-Null
  $longOut = Receive-Job $long -ErrorAction SilentlyContinue
  Remove-Job $long -Force -ErrorAction SilentlyContinue
  Log "killed-run-outcome=$($longOut | Select-Object -Last 1)"

  # Phase 3, restart against the same store files: same config, same db,
  # same tails, same registry sidecar.
  $server = Start-Process -FilePath (Join-Path $RepoRoot "agent\target\debug\calcar-connect.exe") -ArgumentList "--config", (Join-Path $T "agent.conf") -WindowStyle Hidden -PassThru
  $ready = $false
  for ($i = 0; $i -lt 15 -and -not $ready; $i++) {
    Start-Sleep -Seconds 1
    if ($server.HasExited) { break }
    $code = curl.exe -s -o NUL -w '%{http_code}' -H "Authorization: Bearer $Token" "$Base/v1/agent/computers/pc-resume/workflows/wf-resume" 2>$null
    if ($code -eq "200") { $ready = $true }
  }
  Check "restart-boot" ($ready) "HasExited=$($server.HasExited)"
  if (-not $ready) { Log "FAIL server never came back"; exit 1 }

  # Reattach: same prior non-terminal state, never completed by the kill.
  $s1 = Get-Snap "wf-resume"
  Check "reattach-same-state" ($s1.status -eq $s0.status -and $s1.status -ne "completed") "before=$($s0.status) after=$($s1.status)"

  # Replay: every pre-kill event id is still in the ring, high-water mark
  # never moved backwards.
  $ids1 = @($s1.activity | ForEach-Object { $_.event_id })
  $missing = @($ids0 | Where-Object { $ids1 -notcontains $_ })
  $seq1 = [int]$s1.last_seq_no
  Check "replayed-ring" ($missing.Count -eq 0 -and $seq1 -ge $seq0) "missing=$($missing -join ',') before=$seq0 after=$seq1"

  # Monotonic: seqs contiguous from 1 with no duplicates and no gaps, and
  # the mark equals the max. Trim never triggers at this volume, so any
  # fork or repeat across the kill would show here.
  $seqs1 = @($s1.activity | ForEach-Object { [int]$_.seq_no } | Sort-Object)
  $contig = ($seqs1.Count -gt 0 -and $seqs1[0] -eq 1 -and $seqs1[-1] -eq $seq1 -and $seqs1.Count -eq $seq1)
  for ($i = 1; $i -lt $seqs1.Count -and $contig; $i++) { if ($seqs1[$i] -ne $seqs1[$i-1] + 1) { $contig = $false } }
  Check "ring-monotonic" ($contig) "seqs=$($seqs1 -join ',') mark=$seq1"

  # No duplicated completions: the pre-kill input completed exactly once.
  $c1post = @($s1.activity | Where-Object { $_.summary -like "*input r1 completed*" }).Count
  Check "no-dup-completions" ($c1post -eq 1) "r1completedx$c1post"

  # Dedupe survives the restart: the pre-kill UUID is a duplicate, a fresh
  # UUID still delivers.
  $r1again = Post-Input "wf-resume" "r1" "echo RESUME_ONE"
  Check "postkill-dedupe" ($r1again.outcome -eq "duplicate") "r1=$($r1again | ConvertTo-Json -Compress)"
  $d2 = Post-Input "wf-resume" "r2" "echo RESUME_TWO"
  Check "postkill-new-delivers" ($d2.outcome -eq "delivered" -and $d2.exit_code -eq 0) "r2=$($d2 | ConvertTo-Json -Compress)"

  $s2 = Get-Snap "wf-resume"
  $seq2 = [int]$s2.last_seq_no
  $c1final = @($s2.activity | Where-Object { $_.summary -like "*input r1 completed*" }).Count
  $c2final = @($s2.activity | Where-Object { $_.summary -like "*input r2 completed*" }).Count
  Check "ring-grew" ($seq2 -gt $seq0 -and $c1final -eq 1 -and $c2final -eq 1) "before=$seq0 after=$seq2 r1x$c1final r2x$c2final"
  Check "never-completed" ($s0.status -ne "completed" -and $s1.status -ne "completed" -and $s2.status -ne "completed") "s0=$($s0.status) s1=$($s1.status) s2=$($s2.status)"
  $tail1 = Get-Content (Join-Path $T "tails\wf-resume-r1.log") -Raw -ErrorAction SilentlyContinue
  $tail2 = Get-Content (Join-Path $T "tails\wf-resume-r2.log") -Raw -ErrorAction SilentlyContinue
  Check "tail-bytes-postkill" (($tail1 -match "RESUME_ONE") -and ($tail2 -match "RESUME_TWO")) "t1=$tail1 t2=$tail2"

  Log "step=leak-sweep"
  $leaks = tasklist /NH /FO CSV | Select-String -Pattern '"ping.exe"'
  if ($leaks) { Log "WARN ping stragglers remain:"; $leaks | Tee-Object -Append -FilePath $LogFile }
  else { Log "pass=no-ping-stragglers" }

  Set-Location $RepoRoot
  if ($failures -eq 0) { Log "GREEN restart resumed the same session with replay and no dupes" } else { Log "RED failures=$failures"; exit 1 }
}
finally {
  Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
  Set-Location $RepoRoot
}
