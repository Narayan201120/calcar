# privacy-grep.ps1 - canary sweep over a live agent run. Windows only.
# Seeds unique canary strings as workflow content, runs them through exec,
# then asserts they appear ONLY where the design allows: the PTY tail file
# on disk. Server logs, event summaries, and snapshots must be clean.
# Resolve payloads retaining input text are reported, not failed: see DEC.
$ErrorActionPreference = "Stop"

$RepoRoot = (Get-Location).Path
$LogDir = Join-Path $RepoRoot "target/privacy-grep"
$LogFile = Join-Path $LogDir "privacy-grep.log"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
if (Test-Path $LogFile) { Remove-Item $LogFile }

function Log($msg) {
  $line = "[privacy-grep] $msg"
  Write-Host $line
  Add-Content -Path $LogFile -Value $line
}

$failures = 0
function Check($name, $cond, $detail) {
  if ($cond) { Log "PASS $name" }
  else { Log "FAIL $name : $detail"; $script:failures++ }
}

$T = Join-Path $env:TEMP "calcar-privacy"
New-Item -ItemType Directory -Force -Path $T | Out-Null
$Port = 18424
$Base = "http://127.0.0.1:$Port"
$Token = "privacy-token-xyz"
$H = "Authorization: Bearer $Token"

$CanaryPrompt = "CANARY_PROMPT_ALPHA_7Q9Z"
$CanaryKey = "sk-canary-9F8E7D6C5B4A"

Log "start os=$([Environment]::OSVersion.VersionString)"
Set-Location (Join-Path $RepoRoot "agent")
# cargo prints status to stderr, which reads as failure under the
# stop-on-error preference. Run it permissively, then judge by the
# exit code alone.
$prevPref = $ErrorActionPreference; $ErrorActionPreference = "Continue"
cargo build -p calcar-connect 2>&1 | Select-Object -Last 1 | Tee-Object -Append -FilePath $LogFile
$buildCode = $LASTEXITCODE
$ErrorActionPreference = $prevPref
if ($buildCode -ne 0) { Log "FAIL cargo build"; exit 1 }

Set-Content (Join-Path $T "token.txt") -NoNewline -Value $Token
Set-Content (Join-Path $T "agent.conf") -Value @(
  "port=$Port",
  "token_file=$T\token.txt",
  "db_path=$T\agent.db",
  "computer_id=pc-priv",
  "display_name=PrivPC",
  "owner_device_id=PH-owner",
  "exec_timeout_secs=30"
)
Remove-Item (Join-Path $T "agent.db") -ErrorAction SilentlyContinue
$SrvOut = Join-Path $T "server-stdout.log"
$SrvErr = Join-Path $T "server-stderr.log"
$server = Start-Process -FilePath (Join-Path $RepoRoot "agent\target\debug\calcar-connect.exe") -ArgumentList "--config", (Join-Path $T "agent.conf") -WindowStyle Hidden -RedirectStandardOutput $SrvOut -RedirectStandardError $SrvErr -PassThru
try {
  Start-Sleep -Seconds 2
  if ($server.HasExited) { Log "FAIL server exited at boot"; exit 1 }

  $w = curl.exe -s -o NUL -w '%{http_code}' -H "Authorization: Bearer $Token" "$Base/v1/agent/computers/pc-priv/workflows/wf-priv"
  Check "warmup" ($w -eq "404") "warm=$w"
  & 'C:\Program Files\Python312\python.exe' -c "import sqlite3,time; now=int(time.time()*1000); c=sqlite3.connect(r'$T\agent.db'); c.execute('INSERT INTO workflows VALUES (?,?,?,?,?,?,?)',('wf-priv',4,1,'Priv flow','ps-priv',now,now)); c.commit(); print('seeded', c.total_changes)" | Tee-Object -Append -FilePath $LogFile

  # Canary runs through exec as workflow content: prompt-shaped input
  # plus key-shaped output.
  $canaryBody = "echo $CanaryPrompt $CanaryKey"
  Set-Content (Join-Path $T "in.json") -NoNewline -Value (@{input_id = "in-priv"; body = $canaryBody; destructive = $false} | ConvertTo-Json -Compress)
  $in = curl.exe -s -X POST -H $H -H 'X-Request-ID: in-priv' -H 'Content-Type: application/json' --data-binary "@$T\in.json" "$Base/v1/agent/workflows/wf-priv/inputs" | ConvertFrom-Json
  Check "canary-executed" ($in.outcome -eq "delivered" -and $in.exit_code -eq 0) "body=$($in | ConvertTo-Json -Compress)"
  $snap = curl.exe -s -H $H "$Base/v1/agent/computers/pc-priv/workflows/wf-priv" | ConvertFrom-Json
  Check "ring-grew" ($snap.last_seq_no -ge 2) "seq=$($snap.last_seq_no)"

  Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 1

  # Positive control first: the tail file MUST hold the canary, or the
  # grep chain below proves nothing.
  $tailHit = Select-String -Path (Join-Path $T "tails/*") -Pattern $CanaryPrompt -ErrorAction SilentlyContinue | Select-Object -First 1
  Check "positive-control-tail" ($null -ne $tailHit) "canary absent from tail files, grep chain unproven"

  # Server logs must never carry workflow content or the bearer token.
  $logHit = Select-String -Path $SrvOut, $SrvErr -Pattern "$CanaryPrompt|$CanaryKey|$Token" -ErrorAction SilentlyContinue | Select-Object -First 1
  Check "server-logs-clean" ($null -eq $logHit) "hit=$($logHit | Select-Object -First 1)"

  # Event summaries must never carry workflow content. Checked through
  # SQL so binarypage noise cannot hide a hit.
  $dbHits = & 'C:\Program Files\Python312\python.exe' -c "import sqlite3; c=sqlite3.connect(r'$T\agent.db'); n=0
for (table, col) in [('workflow_events','summary')]:
    for (v,) in c.execute(f'SELECT {col} FROM {table}'):
        s = v or ''
        if '$CanaryPrompt' in s or '$CanaryKey' in s: n += 1
print(n)"
  Check "event-summaries-clean" ($dbHits.Trim() -eq "0") "hits=$dbHits"

  # Snapshot bodies must never carry workflow content.
  $snapText = $snap | ConvertTo-Json -Compress -Depth 4
  Check "snapshot-clean" ($snapText -notmatch $CanaryPrompt -and $snapText -notmatch $CanaryKey) "leak in snapshot body"

  # resolve_payload must not retain workflow input text (DEC-040 removed
  # the only writer; the sweep asserts the column stays clean every run).
  $PyCheck = Join-Path $T "check_resolve.py"
  Set-Content $PyCheck 'import os, sqlite3'
  Add-Content $PyCheck ('c = sqlite3.connect(r"' + $T + '\agent.db")')
  Add-Content $PyCheck 'n = 0'
  Add-Content $PyCheck 'prom = os.environ.get("CALCAR_CANARY_PROMPT", "")'
  Add-Content $PyCheck 'key = os.environ.get("CALCAR_CANARY_KEY", "")'
  Add-Content $PyCheck 'for (v,) in c.execute("SELECT resolve_payload FROM pending_requests"):'
  Add-Content $PyCheck '    s = v if isinstance(v, bytes) else (v or "").encode()'
  Add-Content $PyCheck '    ux = (prom and prom.encode() in s) or (key and key.encode() in s)'
  Add-Content $PyCheck '    if ux: n += 1'
  Add-Content $PyCheck 'print(n)'
  $env:CALCAR_CANARY_PROMPT = $CanaryPrompt
  $env:CALCAR_CANARY_KEY = $CanaryKey
  $retained = & 'C:\Program Files\Python312\python.exe' $PyCheck
  Remove-Item Env:\CALCAR_CANARY_PROMPT -ErrorAction SilentlyContinue
  Remove-Item Env:\CALCAR_CANARY_KEY -ErrorAction SilentlyContinue
  Check "resolve-payload-drops-input-text" ($retained.Trim() -eq "0") "retained=$retained"

  Set-Location $RepoRoot
  if ($failures -eq 0) { Log "GREEN telemetry clean, tail holds the canary" } else { Log "RED failures=$failures"; exit 1 }
}
finally {
  Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
  Set-Location $RepoRoot
}
