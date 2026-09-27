# e2e-drop.ps1 - 60 second outage with resume and replay. Windows only.
# A long command runs while contact stops for a full minute. On return,
# retried UUIDs must duplicate, new ones deliver, the ring must show no
# gap and no repeat, and the workflow must still be alive.
$ErrorActionPreference = "Stop"

$RepoRoot = (Get-Location).Path
$LogDir = Join-Path $RepoRoot "target/e2e-drop"
$LogFile = Join-Path $LogDir "e2e-drop.log"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
if (Test-Path $LogFile) { Remove-Item $LogFile }

function Log($msg) {
  $line = "[e2e-drop] $msg"
  Write-Host $line
  Add-Content -Path $LogFile -Value $line
}

$failures = 0
function Check($name, $cond, $detail) {
  if ($cond) { Log "PASS $name" }
  else { Log "FAIL $name : $detail"; $script:failures++ }
}

$T = Join-Path $env:TEMP "calcar-e2e-drop"
New-Item -ItemType Directory -Force -Path $T | Out-Null
$Port = 18423
$Base = "http://127.0.0.1:$Port"
$Token = "drop-token-abc"
$H = "Authorization: Bearer $Token"

Log "start os=$([Environment]::OSVersion.VersionString)"
Set-Location (Join-Path $RepoRoot "agent")
cargo build -p calcar-connect 2>&1 | Select-Object -Last 1 | Tee-Object -Append -FilePath $LogFile
if ($LASTEXITCODE -ne 0) { Log "FAIL cargo build"; exit 1 }

Set-Content (Join-Path $T "token.txt") -NoNewline -Value $Token
Set-Content (Join-Path $T "agent.conf") -Value @(
  "port=$Port",
  "token_file=$T\token.txt",
  "db_path=$T\agent.db",
  "computer_id=pc-drop",
  "display_name=DropPC",
  "owner_device_id=PH-owner",
  "exec_timeout_secs=90"
)
Remove-Item (Join-Path $T "agent.db") -ErrorAction SilentlyContinue
$server = Start-Process -FilePath (Join-Path $RepoRoot "agent\target\debug\calcar-connect.exe") -ArgumentList "--config", (Join-Path $T "agent.conf") -WindowStyle Hidden -PassThru
try {
  Start-Sleep -Seconds 2
  if ($server.HasExited) { Log "FAIL server exited at boot"; exit 1 }

  $w = curl.exe -s -o NUL -w '%{http_code}' -H "Authorization: Bearer $Token" "$Base/v1/agent/computers/pc-drop/workflows/wf-drop"
  Check "warmup" ($w -eq "404") "warm=$w"
  & 'C:\Program Files\Python312\python.exe' -c "import sqlite3,time; now=int(time.time()*1000); c=sqlite3.connect(r'$T\agent.db'); c.execute('INSERT INTO workflows VALUES (?,?,?,?,?,?,?)',('wf-drop',4,1,'Drop flow','ps-drop',now,now)); c.commit(); print('seeded', c.total_changes)" | Tee-Object -Append -FilePath $LogFile

  function Post-Input($id, $body) {
    Set-Content (Join-Path $T "$id.json") -NoNewline -Value (@{input_id = $id; body = $body; destructive = $false} | ConvertTo-Json -Compress)
    return curl.exe -s -X POST -H $H -H "X-Request-ID: $id" -H 'Content-Type: application/json' --data-binary "@$T\$id.json" "$Base/v1/agent/workflows/wf-drop/inputs" | ConvertFrom-Json
  }

  # Phase 1, connected: two inputs delivered.
  $d1 = Post-Input "d1" "echo DROP_ONE"
  $d2 = Post-Input "d2" "echo DROP_TWO"
  Check "phase1-delivered" ($d1.outcome -eq "delivered" -and $d2.outcome -eq "delivered") "d1=$($d1.outcome) d2=$($d2.outcome)"
  $s0 = curl.exe -s -H $H "$Base/v1/agent/computers/pc-drop/workflows/wf-drop" | ConvertFrom-Json
  Check "phase1-ring" ($s0.last_seq_no -ge 4) "seq=$($s0.last_seq_no)"

  # Phase 2, outage: a long command starts in the background, then a full
  # minute with zero agent contact.
  Set-Content (Join-Path $T "d-long.json") -NoNewline -Value '{"input_id":"d-long","body":"ping -n 70 127.0.0.1","destructive":false}'
  $long = Start-Job -ScriptBlock {
    param($Base, $H, $T)
    curl.exe -s -X POST -H $H -H 'X-Request-ID: d-long' -H 'Content-Type: application/json' --data-binary "@$T\d-long.json" "$Base/v1/agent/workflows/wf-drop/inputs"
  } -ArgumentList $Base, $H, $T
  Start-Sleep -Seconds 5
  Log "outage begins, 60 seconds of silence"
  Start-Sleep -Seconds 60
  Log "outage ends"

  # Phase 3, reconnect: retries must duplicate, new input delivers.
  $r1 = Post-Input "d1" "echo DROP_ONE"
  $r2 = Post-Input "d2" "echo DROP_TWO"
  Check "reconnect-duplicates" ($r1.outcome -eq "duplicate" -and $r2.outcome -eq "duplicate") "r1=$($r1.outcome) r2=$($r2.outcome)"
  $d3 = Post-Input "d3" "echo DROP_THREE"
  Check "reconnect-new-delivers" ($d3.outcome -eq "delivered" -and $d3.exit_code -eq 0) "d3=$($d3 | ConvertTo-Json -Compress)"

  $longOut = Wait-Job $long -Timeout 60 | Receive-Job
  Remove-Job $long -Force -ErrorAction SilentlyContinue
  $longJson = $longOut | Select-Object -Last 1 | ConvertFrom-Json
  Check "long-survived" ($longJson.outcome -eq "delivered") "long=$($longJson | ConvertTo-Json -Compress)"

  $s1 = curl.exe -s -H $H "$Base/v1/agent/computers/pc-drop/workflows/wf-drop" | ConvertFrom-Json
  $texts = @($s1.activity | ForEach-Object { $_.summary })
  $c1 = @($texts | Where-Object { $_ -like "*d1 completed*" }).Count
  $c2 = @($texts | Where-Object { $_ -like "*d2 completed*" }).Count
  Check "ring-no-repeats" ($c1 -eq 1 -and $c2 -eq 1) "d1x$c1 d2x$c2"
  Check "ring-grew" ($s1.last_seq_no -gt $s0.last_seq_no) "before=$($s0.last_seq_no) after=$($s1.last_seq_no)"
  Check "workflow-alive" ($s1.status -ne "completed") "status=$($s1.status)"

  Set-Location $RepoRoot
  if ($failures -eq 0) { Log "GREEN outage survived with no dupes and no loss" } else { Log "RED failures=$failures"; exit 1 }
}
finally {
  Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
  Set-Location $RepoRoot
}
