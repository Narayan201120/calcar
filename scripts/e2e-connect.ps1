# e2e-connect.ps1 - generic end to end through calcar-connect. Windows only.
# Builds the binary, serves a seeded store, and asserts the phone-shaped
# surface with curl. Repeatable artifact: this script plus its console log.
$ErrorActionPreference = "Stop"

$RepoRoot = (Get-Location).Path
$LogDir = Join-Path $RepoRoot "target/e2e-connect"
$LogFile = Join-Path $LogDir "e2e-connect.log"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
if (Test-Path $LogFile) { Remove-Item $LogFile }

function Log($msg) {
  $line = "[e2e-connect] $msg"
  Write-Host $line
  Add-Content -Path $LogFile -Value $line
}

$failures = 0
function Check($name, $cond, $detail) {
  if ($cond) { Log "PASS $name" }
  else { Log "FAIL $name : $detail"; $script:failures++ }
}

$T = Join-Path $env:TEMP "calcar-e2e-connect"
New-Item -ItemType Directory -Force -Path $T | Out-Null
$Port = 18422
$Base = "http://127.0.0.1:$Port"
$Token = "e2e-token-abc"

Log "start os=$([Environment]::OSVersion.VersionString)"
Set-Location (Join-Path $RepoRoot "agent")
cargo build -p calcar-connect 2>&1 | Select-Object -Last 1 | Tee-Object -Append -FilePath $LogFile
if ($LASTEXITCODE -ne 0) { Log "FAIL cargo build"; exit 1 }

Set-Content (Join-Path $T "token.txt") -NoNewline -Value $Token
Set-Content (Join-Path $T "agent.conf") -Value @(
  "port=$Port",
  "token_file=$T\token.txt",
  "db_path=$T\agent.db",
  "computer_id=pc-e2e",
  "display_name=E2EPC",
  "owner_device_id=PH-owner",
  "exec_timeout_secs=30"
)
Remove-Item (Join-Path $T "agent.db") -ErrorAction SilentlyContinue
$server = Start-Process -FilePath (Join-Path $RepoRoot "agent\target\debug\calcar-connect.exe") -ArgumentList "--config", (Join-Path $T "agent.conf") -WindowStyle Hidden -PassThru
try {
  Start-Sleep -Seconds 2
  if ($server.HasExited) { Log "FAIL server exited at boot"; exit 1 }

  # Warm-up on a store route migrates SQLite, then seed through sqlite
  # like the production code paths do. The devices route serves the
  # registry sidecar and never touches the database.
  $w = curl.exe -s -o NUL -w '%{http_code}' -H "Authorization: Bearer $Token" "$Base/v1/agent/computers/pc-e2e/workflows/wf-e2e"
  Check "warmup" ($w -eq "404") "warm=$w"
  & 'C:\Program Files\Python312\python.exe' -c "import sqlite3,time; now=int(time.time()*1000); c=sqlite3.connect(r'$T\agent.db'); c.execute('INSERT INTO workflows VALUES (?,?,?,?,?,?,?)',('wf-e2e',4,3,'E2E flow','ps-e2e',now,now)); c.execute('INSERT INTO workflows VALUES (?,?,?,?,?,?,?)',('wf-inter',1,1,'Inter flow',None,now,now)); c.execute('INSERT INTO pending_requests VALUES (?,?,?,?,?,?,?,?)',('appr-e','wf-e2e',2,1,now,now+600000,None,None)); c.execute('INSERT INTO pending_requests VALUES (?,?,?,?,?,?,?,?)',('appr-rt','wf-e2e',2,1,now,now+600000,None,None)); c.execute('INSERT INTO pending_requests VALUES (?,?,?,?,?,?,?,?)',('appr-exp','wf-e2e',2,1,now-600000,now-60000,None,None)); c.execute('INSERT INTO session_bindings VALUES (?,?,?,?)',('wf-inter','cli-sess-9',None,now)); c.commit(); print('seeded', c.total_changes)" | Tee-Object -Append -FilePath $LogFile

  $H = "Authorization: Bearer $Token"
  $r = curl.exe -s -o NUL -w '%{http_code} %{size_download}' "$Base/v1/agent/devices?user_id=u1"
  Check "no-token-401-empty" ($r -eq "401 0") "got=$r"
  $r = curl.exe -s -o NUL -w '%{http_code} %{size_download}' -H 'Authorization: Bearer wrong' "$Base/v1/agent/devices?user_id=u1"
  Check "wrong-token-401-empty" ($r -eq "401 0") "got=$r"

  $dev = curl.exe -s -H $H "$Base/v1/agent/devices?user_id=u1" | ConvertFrom-Json
  Check "devices-row" ($dev.devices[0].device_id -eq "pc-e2e" -and $dev.devices[0].role -eq "computer") "body=$($dev | ConvertTo-Json -Compress)"

  $comp = curl.exe -s -H $H "$Base/v1/agent/computers/pc-e2e" | ConvertFrom-Json
  Check "computer" ($comp.device_id -eq "pc-e2e") "body=$($comp | ConvertTo-Json -Compress)"
  $sys = curl.exe -s -H $H "$Base/v1/agent/computers/pc-e2e/sysinfo" | ConvertFrom-Json
  Check "sysinfo-keys" ($null -ne $sys.cpu -and $null -ne $sys.ram -and $null -ne $sys.gpu -and $null -ne $sys.disk) "body=$($sys | ConvertTo-Json -Compress)"

  $snap = curl.exe -s -H $H "$Base/v1/agent/computers/pc-e2e/workflows/wf-e2e" | ConvertFrom-Json
  Check "snapshot" ($snap.status -eq "waiting_approval" -and $snap.workflow_id -eq "wf-e2e" -and $snap.last_seq_no -ge 0) "body=$($snap | ConvertTo-Json -Compress -Depth 3)"

  Set-Content (Join-Path $T "appr.json") -NoNewline -Value '{"approval_id":"appr-e","allow":true}'
  $ap = curl.exe -s -X POST -H $H -H 'X-Request-ID: appr-e' -H 'Content-Type: application/json' --data-binary "@$T\appr.json" "$Base/v1/agent/workflows/wf-e2e/approvals" | ConvertFrom-Json
  Check "approve" ($ap.resolution -eq "approved") "body=$($ap | ConvertTo-Json -Compress)"
  $ap2 = curl.exe -s -X POST -H $H -H 'X-Request-ID: appr-e' -H 'Content-Type: application/json' --data-binary "@$T\appr.json" "$Base/v1/agent/workflows/wf-e2e/approvals" | ConvertFrom-Json
  Check "approve-twice-409" ($ap2.code -eq "ALREADY_RESOLVED") "body=$($ap2 | ConvertTo-Json -Compress)"

  Set-Content (Join-Path $T "in.json") -NoNewline -Value '{"input_id":"in-e2e","body":"echo E2E_GENERIC","destructive":false}'
  $in = curl.exe -s -X POST -H $H -H 'X-Request-ID: in-e2e' -H 'Content-Type: application/json' --data-binary "@$T\in.json" "$Base/v1/agent/workflows/wf-e2e/inputs" | ConvertFrom-Json
  Check "input-delivered" ($in.outcome -eq "delivered" -and $in.exit_code -eq 0) "body=$($in | ConvertTo-Json -Compress)"
  $in2 = curl.exe -s -X POST -H $H -H 'X-Request-ID: in-e2e' -H 'Content-Type: application/json' --data-binary "@$T\in.json" "$Base/v1/agent/workflows/wf-e2e/inputs" | ConvertFrom-Json
  Check "input-duplicate" ($in2.outcome -eq "duplicate") "body=$($in2 | ConvertTo-Json -Compress)"

  $snap2 = curl.exe -s -H $H "$Base/v1/agent/computers/pc-e2e/workflows/wf-e2e" | ConvertFrom-Json
  Check "ring-grew" ($snap2.last_seq_no -gt $snap.last_seq_no) "before=$($snap.last_seq_no) after=$($snap2.last_seq_no)"
  $tail = Get-ChildItem (Join-Path $T "tails") -ErrorAction SilentlyContinue | Select-Object -First 1
  $tailText = if ($tail) { Get-Content $tail.FullName -Raw } else { "" }
  Check "tail-bytes" ($tailText -match "E2E_GENERIC") "tail=$tailText"

  Set-Content (Join-Path $T "in-inter.json") -NoNewline -Value '{"input_id":"in-inter","body":"echo HI","destructive":false}'
  $inter = curl.exe -s -X POST -H $H -H 'X-Request-ID: in-inter' -H 'Content-Type: application/json' --data-binary "@$T\in-inter.json" "$Base/v1/agent/workflows/wf-inter/inputs" | ConvertFrom-Json
  Check "interactive-501" ($inter.code -eq "CONPTY_UNAVAILABLE" -and $inter.has_binding -eq $true) "body=$($inter | ConvertTo-Json -Compress)"

  # Approval roundtrip, timed: apply once, duplicates dead, expired dead.
  Set-Content (Join-Path $T "appr-ok.json") -NoNewline -Value '{"approval_id":"appr-rt","allow":true}'
  $t0 = Get-Date
  $rt = curl.exe -s -X POST -H $H -H 'X-Request-ID: appr-rt' -H 'Content-Type: application/json' --data-binary "@$T\appr-ok.json" "$Base/v1/agent/workflows/wf-e2e/approvals" | ConvertFrom-Json
  $ms = [int]((Get-Date) - $t0).TotalMilliseconds
  Check "roundtrip-applied" ($rt.resolution -eq "approved") "body=$($rt | ConvertTo-Json -Compress) ms=$ms"
  Log "roundtrip-ms=$ms"
  $rt2 = curl.exe -s -X POST -H $H -H 'X-Request-ID: appr-rt' -H 'Content-Type: application/json' --data-binary "@$T\appr-ok.json" "$Base/v1/agent/workflows/wf-e2e/approvals" | ConvertFrom-Json
  Check "roundtrip-duplicate-dead" ($rt2.code -eq "ALREADY_RESOLVED") "body=$($rt2 | ConvertTo-Json -Compress)"
  Set-Content (Join-Path $T "appr-no.json") -NoNewline -Value '{"approval_id":"appr-missing","allow":true}'
  $rt3 = curl.exe -s -X POST -H $H -H 'X-Request-ID: appr-missing' -H 'Content-Type: application/json' --data-binary "@$T\appr-no.json" "$Base/v1/agent/workflows/wf-e2e/approvals" | ConvertFrom-Json
  Check "roundtrip-unknown-dead" ($rt3.code -eq "APPROVAL_UNKNOWN") "body=$($rt3 | ConvertTo-Json -Compress)"
  Set-Content (Join-Path $T "appr-exp.json") -NoNewline -Value '{"approval_id":"appr-exp","allow":true}'
  $rt4 = curl.exe -s -X POST -H $H -H 'X-Request-ID: appr-exp' -H 'Content-Type: application/json' --data-binary "@$T\appr-exp.json" "$Base/v1/agent/workflows/wf-e2e/approvals" | ConvertFrom-Json
  Check "roundtrip-expired-dead" ($rt4.code -eq "EXPIRED") "body=$($rt4 | ConvertTo-Json -Compress)"
  $rt5 = curl.exe -s -X POST -H $H -H 'X-Request-ID: wrong-key' -H 'Content-Type: application/json' --data-binary "@$T\appr-ok.json" "$Base/v1/agent/workflows/wf-e2e/approvals" | ConvertFrom-Json
  Check "roundtrip-key-mismatch-dead" ($rt5.code -eq "MALFORMED") "body=$($rt5 | ConvertTo-Json -Compress)"
  $snap3 = curl.exe -s -H $H "$Base/v1/agent/computers/pc-e2e/workflows/wf-e2e" | ConvertFrom-Json
  $verdict = @($snap3.approvals | Where-Object { $_.approval_id -eq "appr-rt" })
  Check "roundtrip-verdict-in-ring" ($verdict.Count -eq 1 -and $verdict[0].resolution -eq "approved") "approvals=$($snap3.approvals | ConvertTo-Json -Compress)"

  Set-Location $RepoRoot
  if ($failures -eq 0) { Log "GREEN generic end to end held" } else { Log "RED failures=$failures"; exit 1 }
}
finally {
  Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
  Set-Location $RepoRoot
}
