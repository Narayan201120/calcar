# P8 SLOs and metrics runbook

Scope: no Prometheus or OpenTelemetry yet. Backend README marks metrics
deferred, so each SLO is checked with curl, a script log in target/, or a
test suite. Trust codes are PAIRING_EXPIRED, PAIRING_CONSUMED,
PUBKEY_MISMATCH, NOT_OWNER, REPLAYED_ID, REVOKED, UNKNOWN_SESSION.

Sessions live 10 minutes, single use (PairingTTL, pairing-spec 4).
Timestamps must sit inside 5 minutes of skew (pairing-spec 5, 9). Access
tokens live 24 hours, refresh tokens 30 days, single use. Challenges live
2 minutes.

Note: the README names intended request fields (ts, level, msg, method,
path, status, latency_ms) but no such emitter exists in code today, so any
SLO needing server side latency percentiles is OPEN until it lands.

## Pairing join success
Objective: a fresh session accepts exactly one join and one decision, and
every other attempt fails closed.
Target: scripts/e2e-pairing.ps1 green on 100 percent of runs.
Measure: run `powershell scripts/e2e-pairing.ps1`, then grep
target/e2e-pairing/e2e-pairing.log for `PASS join-loop-pass`,
`join landed`, and the garbage session refusal (UNKNOWN_SESSION or
PAIRING_CONSUMED, no state change).
OPEN: create, join, decision latency bounds. pcjoin prints no timings.
Needs curl `-w` timing or OpenTelemetry histograms.

## Approval roundtrip correctness
Objective: each approval resolves exactly once; late or wrong retries stay
dead.
Target: 100 percent single resolve across runs.
Measure: run `powershell scripts/e2e-connect.ps1`, then grep
target/e2e-connect/e2e-connect.log for `PASS roundtrip-*`,
`PASS roundtrip-verdict-in-ring`, and `roundtrip-ms=`. Codes: approved,
ALREADY_RESOLVED, APPROVAL_UNKNOWN, EXPIRED, MALFORMED.
OPEN: latency percentile. One loopback sample per run is not a
distribution. Needs repeated timed applies plus the P7 latency split.

## Command delivery
Objective: sent inputs are acked and applied once; retries dedupe.
Target: 100 percent first send delivered, 100 percent same X-Request-ID
returned duplicate.
Measure: same e2e-connect log, grep `PASS input-delivered`,
`PASS input-duplicate`, `PASS ring-grew`, `PASS tail-bytes`.

## Reconnect resume with no dupes
Objective: a 60 second outage or kill -9 restart loses and duplicates
nothing.
Target: retried UUIDs duplicate 100 percent, new inputs deliver 100
percent, each pre outage completion appears once, ring seqs contiguous
from 1 with mark equal to max, workflow never completes on disconnect.
Measure: run `powershell scripts/e2e-drop.ps1` and
`powershell scripts/e2e-resume.ps1`. Grep target/e2e-drop/e2e-drop.log for
`PASS reconnect-duplicates`, `PASS reconnect-new-delivers`,
`PASS ring-no-repeats`, `PASS long-survived`, `PASS workflow-alive`. Grep
target/e2e-resume/e2e-resume.log for `PASS reattach-same-state`,
`PASS replayed-ring`, `PASS ring-monotonic`, `PASS no-dup-completions`,
`PASS postkill-dedupe`, `PASS postkill-new-delivers`.

## Revoke propagation
Objective: a revoked device loses access at once when online and on the
next check when offline.
Target: 100 percent of post revoke calls rejected; a live Owner WS gets
trust.revoked naming the subject.
Measure: run `powershell scripts/e2e-revoke.ps1`, grep
target/e2e-revoke/e2e-revoke.log for `PASS` on `revoke-loop-pass` (10 or
more `revoke PASS` lines), `online propagation`, `heartbeat rejected`,
`devices rejected`, `decision rejected`, `verify refused`,
`reconnect refused`, `unauth-revoke-refused`. Unit cover:
backend/api/revoke_test.go plus `go test ./api/`.
OPEN: propagation seconds. No timestamps sit between revoke write and first
reject. Needs millis on commit, WS event, and first 401.

## WS heartbeat survival
Objective: a conn that answers heartbeats stays up; a silent one is cut.
Target: `{"type":"heartbeat"}` at least every 30 seconds keeps the conn
(hbInterval, hub.go); 3 missed windows, about 90 seconds, drops it.
Measure: `go test ./ws/ ./api/ -count=1` from backend, plus e2e-revoke.log
`pre-revoke heartbeat ok` then `heartbeat rejected after revoke`.

## Zero illicit auths
Objective: no auth without Owner tap, exact pubkey binding, live grant.
Target: 0 illicit auths.
Measure: `go test ./trust/ ./api/ ./ws/ -count=1` from backend (attacker
signer, swapped pubkey, spoofed signature, replayed id, double approve,
expired session, NOT_OWNER 403, REVOKED 401 or 403, REPLAYED_ID 409).
Live: e2e-pairing garbage refused, e2e-revoke unauth 401 plus all post
revoke rejects, e2e-connect wrong token 401 with empty body.

## Backend /readyz availability
Objective: liveness apart from readiness, so the edge never routes to a
backend with dead stores.
Target: /healthz 200 with no deps; /readyz 200 only when Postgres plus
Redis Ping answer, else 503 (server_test.go covers both).
Measure: `curl -s -o NUL -w "%{http_code}" localhost:8080/healthz`, repeat
for /readyz. Compose gates start on pg_isready plus redis-cli ping.
OPEN: windowed availability percent. Needs a prober plus counters.

## Update manifest freshness
Objective: each shipped APK has a matching entry at a stable URL.
Target: each mobile-<run> release carries update.json with
latest.versionCode equal to the run number, https apkUrl, 64 char hex
sha256 (mobile-apk.yml); served at kUpdateManifestUrl
(update_controller.dart).
Measure: `curl -s https://github.com/Narayan201120/calcar/releases/latest/download/update.json`
and compare versionCode. Parser cover: `flutter test
test/update_manifest_test.dart test/update_service_test.dart` from mobile.

## Mobile render timings
OPEN: approval push to rendered and cold start to cached list. Widget
tests assert rendering and inert states only (approval_test.dart,
workflow_test.dart). Needs push receipt to first frame and cold start to
cached then refreshed list, median and p95 as P7 asks.

## Privacy audit
Objective: ban list material never leaves its boundary (tokens, keys,
workflow bodies, push detail).
Target: zero canary hits outside the PTY tail file.
Measure: run `powershell scripts/privacy-grep.ps1`, grep
target/privacy-grep/privacy-grep.log for `PASS snapshot-clean` and
`PASS positive-control-tail`, which must pass or the sweep proves nothing.

## Full gate order
Run from root: e2e-pairing, e2e-revoke, e2e-refresh, e2e-connect, e2e-drop,
e2e-resume, privacy-grep, then `go test ./trust/ ./api/ ./ws/` from
backend. Each log lands under target/ by script name.
