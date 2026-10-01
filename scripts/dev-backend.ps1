# dev-backend.ps1 - durable local backend without Docker. Windows only.
# Starts the user-space Postgres 18 cluster on :5433, Redis 8 in WSL on
# :6379, then calcar-api on :8080 against both. Data survives restarts
# in LocalAppData and ~/.calcar-redis. Repeatable: run, check /readyz.
$ErrorActionPreference = "Stop"

$PgBin = 'C:\Program Files\PostgreSQL\18\bin'
$PgData = 'C:\Users\naray\AppData\Local\calcar\pgdata'
$ApiExe = 'C:\Users\naray\AppData\Local\Temp\calcar-live\calcar-api.exe'

& "$PgBin\pg_ctl.exe" -D $PgData -l "$PgData.log" -w -t 30 start 2>&1 | Select-Object -Last 1
wsl -e sh -c 'export LD_LIBRARY_PATH=$HOME/.calcar-redis/lib/usr/lib/x86_64-linux-gnu; ~/.calcar-redis/root/usr/bin/redis-cli -p 6379 ping 2>/dev/null || (mkdir -p ~/.calcar-redis/data && ~/.calcar-redis/root/usr/bin/redis-server --port 6379 --appendonly yes --dir ~/.calcar-redis/data --daemonize yes --save "60 1")' 2>&1 | Select-Object -Last 1

Stop-Process -Name calcar-api -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
$env:PORT = '8080'
$env:PG_DSN = 'postgres://calcar:calcar-dev-only-change-me@localhost:5433/calcar?sslmode=disable'
$env:REDIS_ADDR = 'localhost:6379'
Start-Process -FilePath $ApiExe -WindowStyle Hidden
Start-Sleep -Seconds 5
curl.exe -s 'http://127.0.0.1:8080/readyz'; echo ''
