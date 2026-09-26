// E2E proof runner for the plain-pipe pivot. Driven by scripts/e2e-exec.ps1.
// Not a unit test file: every step exercises real processes and a real
// SQLite file, and prints PASS lines a reviewer can diff. Deleted only if
// the E2E script stops using it.
use calcar_events::{Provider, WorkflowState};
use calcar_pty::plain::{PlainChild, PlainConfig};
use calcar_storage::Storage;
use calcar_workflow::{
    InputRouter, RecoveryDecision, RouteOutcome, SessionManager, WorkflowManager,
};
use std::time::Duration;

static mut FAILURES: u32 = 0;

fn check(name: &str, cond: bool, detail: String) {
    if cond {
        println!("PASS {name}");
    } else {
        println!("FAIL {name}: {detail}");
        unsafe {
            FAILURES += 1;
        }
    }
}

fn tasklist_has(pid: u32) -> bool {
    let out = std::process::Command::new("tasklist")
        .args(["/FI", &format!("PID eq {pid}"), "/NH", "/FO", "CSV"])
        .output()
        .expect("tasklist");
    let text = String::from_utf8_lossy(&out.stdout);
    text.lines().any(|l| l.contains(&format!("\"{pid}\"")))
}

fn plain(cmd: &[&str]) -> PlainConfig {
    PlainConfig::new(cmd.iter().map(|s| s.to_string()).collect())
}

fn main() {
    // ---- plain executor ----
    let out = PlainChild::spawn(plain(&["cmd.exe", "/Q", "/C", "echo HELLO"]))
        .expect("spawn echo")
        .join(Duration::from_secs(20))
        .expect("join echo");
    check(
        "plain-echo",
        out.exit_code == Some(0)
            && String::from_utf8_lossy(&out.stdout).contains("HELLO")
            && out.stderr.is_empty(),
        format!(
            "exit={:?} out={:?} err={:?}",
            out.exit_code,
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        ),
    );

    let out = PlainChild::spawn(plain(&[
        "cmd.exe",
        "/Q",
        "/C",
        "(echo OUT) & (echo ERR 1>&2)",
    ]))
    .expect("spawn split")
    .join(Duration::from_secs(20))
    .expect("join split");
    check(
        "plain-split",
        String::from_utf8_lossy(&out.stdout).contains("OUT")
            && String::from_utf8_lossy(&out.stderr).contains("ERR"),
        format!(
            "out={:?} err={:?}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        ),
    );

    let out = PlainChild::spawn(plain(&["cmd.exe", "/Q", "/C", "exit 42"]))
        .expect("spawn exit42")
        .join(Duration::from_secs(20))
        .expect("join exit42");
    check(
        "plain-exit-code",
        out.exit_code == Some(42),
        format!("exit={:?}", out.exit_code),
    );

    let cfg = PlainConfig::new(vec![
        "cmd.exe".into(),
        "/Q".into(),
        "/C".into(),
        "more".into(),
    ])
    .with_input(b"LINE1\r\nLINE2\r\n".to_vec());
    let out = PlainChild::spawn(cfg)
        .expect("spawn more")
        .join(Duration::from_secs(20))
        .expect("join more");
    let text = String::from_utf8_lossy(&out.stdout).to_string();
    check(
        "plain-stdin",
        text.contains("LINE1") && text.contains("LINE2"),
        format!("out={text:?}"),
    );

    let mut cfg = plain(&[
        "cmd.exe",
        "/Q",
        "/C",
        "for /L %i in (1,1,2000) do @echo line-%i",
    ]);
    cfg.output_cap_bytes = 4096;
    let out = PlainChild::spawn(cfg)
        .expect("spawn cap")
        .join(Duration::from_secs(30))
        .expect("join cap");
    check(
        "plain-cap",
        out.truncated && out.stdout.len() <= 4096 && out.stderr.len() <= 4096,
        format!(
            "truncated={} lens={}/{}",
            out.truncated,
            out.stdout.len(),
            out.stderr.len()
        ),
    );

    let script = "$c = Start-Process -FilePath ping -ArgumentList '-n','60','127.0.0.1' -WindowStyle Hidden -PassThru; Write-Output (\"GRANDCHILD=\" + $c.Id); Start-Sleep -Seconds 60";
    let child = PlainChild::spawn(plain(&[
        "powershell.exe",
        "-NoProfile",
        "-NonInteractive",
        "-Command",
        script,
    ]))
    .expect("spawn tree");
    std::thread::sleep(Duration::from_secs(4));
    let snap = child.snapshot();
    let grandchild: u32 = String::from_utf8_lossy(&snap.stdout)
        .lines()
        .find_map(|l| l.trim().strip_prefix("GRANDCHILD="))
        .and_then(|v| v.trim().parse().ok())
        .expect("grandchild pid in snapshot");
    check(
        "plain-tree-grandchild-alive",
        tasklist_has(grandchild),
        format!("gc={grandchild}"),
    );
    child.kill().expect("kill tree");
    let exited = child
        .wait(Some(Duration::from_secs(10)))
        .expect("wait tree");
    check(
        "plain-tree-child-reaped",
        exited.is_some(),
        format!("exit={exited:?}"),
    );
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while tasklist_has(grandchild) && std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(200));
    }
    check(
        "plain-tree-grandchild-dead",
        !tasklist_has(grandchild),
        format!("gc={grandchild} survived"),
    );

    let child =
        PlainChild::spawn(plain(&["ping.exe", "-n", "30", "127.0.0.1"])).expect("spawn sleep");
    let early = child
        .wait(Some(Duration::from_millis(200)))
        .expect("wait deadline");
    check(
        "plain-deadline",
        early.is_none(),
        format!("early={early:?}"),
    );
    child.kill().expect("kill sleep");
    let out = child.join(Duration::from_secs(10)).expect("join sleep");
    check(
        "plain-kill-join",
        out.exit_code.is_some(),
        format!("exit={:?}", out.exit_code),
    );

    let bad = PlainChild::spawn(PlainConfig::new(vec![]));
    check(
        "plain-empty-argv",
        bad.is_err(),
        "empty argv spawned".to_string(),
    );

    let sleeper =
        PlainChild::spawn(plain(&["ping.exe", "-n", "60", "127.0.0.1"])).expect("spawn drop");
    let pid = sleeper.pid();
    drop(sleeper);
    std::thread::sleep(Duration::from_secs(1));
    check(
        "plain-drop-kills-tree",
        !tasklist_has(pid),
        format!("pid={pid} survived drop"),
    );

    // ---- workflow lifecycle, in-memory ----
    let mgr = WorkflowManager::in_memory().expect("in-memory manager");
    let row = mgr
        .create_workflow("wf1", Provider::Generic, "title", Some("sess-1"))
        .expect("create");
    check(
        "flow-create-running",
        WorkflowState::from_i32(row.state) == Some(WorkflowState::Running),
        format!("row={row:?}"),
    );
    check(
        "flow-duplicate",
        mgr.create_workflow("wf1", Provider::Generic, "t", None)
            .is_err(),
        "dup accepted".to_string(),
    );
    check(
        "flow-empty-id",
        mgr.create_workflow("", Provider::Generic, "t", None)
            .is_err(),
        "empty id accepted".to_string(),
    );
    check(
        "flow-unspecified-provider",
        mgr.create_workflow("wfx", Provider::Unspecified, "t", None)
            .is_err(),
        "unspecified accepted".to_string(),
    );
    mgr.transition("wf1", WorkflowState::WaitingApproval, "need owner tap")
        .expect("to approval");
    let events = mgr.events_since("wf1", 0, 100).expect("events");
    check(
        "flow-reason-events",
        events.len() >= 2 && format!("{:?}", events).contains("need owner tap"),
        format!("events={events:?}"),
    );
    check(
        "flow-refuse-projection-target",
        mgr.transition("wf1", WorkflowState::DisconnectedRunning, "x")
            .is_err(),
        "projected state stored".to_string(),
    );
    check(
        "flow-refuse-unspecified",
        mgr.transition("wf1", WorkflowState::Unspecified, "x")
            .is_err(),
        "unspecified stored".to_string(),
    );
    check(
        "flow-refuse-completed-on-disconnect",
        mgr.transition_on_disconnect("wf1", WorkflowState::Completed, "x")
            .is_err(),
        "disconnect completed".to_string(),
    );
    let view = mgr.project_on_disconnect("wf1").expect("project");
    let stored = mgr.get_workflow("wf1").expect("get").expect("row");
    check(
        "flow-projection",
        view.projected == WorkflowState::DisconnectedRunning
            && WorkflowState::from_i32(stored.state) == Some(WorkflowState::WaitingApproval),
        format!("view={view:?} stored={stored:?}"),
    );
    mgr.transition("wf1", WorkflowState::Completed, "done")
        .expect("complete");
    check(
        "flow-terminal-frozen",
        mgr.transition("wf1", WorkflowState::Running, "x").is_err(),
        "move out of completed accepted".to_string(),
    );

    // ---- restart recovery plus session plus router, file-backed ----
    let dir = std::env::temp_dir().join(format!("calcar-e2e-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("tempdir");
    let db = dir.join("agent.db");
    {
        let mgr = WorkflowManager::open(&db).expect("open file");
        mgr.create_workflow("wf-r", Provider::Generic, "restart me", Some("ps-1"))
            .expect("create r");
        mgr.transition("wf-r", WorkflowState::WaitingInput, "waiting")
            .expect("to input");
        mgr.create_workflow("wf-nobind", Provider::Generic, "no bind", None)
            .expect("create nobind");
        mgr.create_workflow("wf-done", Provider::Generic, "done", None)
            .expect("create done");
        mgr.transition("wf-done", WorkflowState::Completed, "done")
            .expect("complete done");
    }
    let mgr2 = WorkflowManager::open(&db).expect("reopen");
    match mgr2.reconcile("wf-r").expect("reconcile r") {
        RecoveryDecision::Reattach {
            provider_session_id,
            last_seq,
            ..
        } => {
            let newest = mgr2
                .events_since("wf-r", 0, 1000)
                .expect("events r")
                .into_iter()
                .map(|e| e.seq_no)
                .max();
            check(
                "recover-reattach",
                provider_session_id == "ps-1" && last_seq == newest,
                format!("session={provider_session_id:?} last={last_seq:?} newest={newest:?}"),
            );
        }
        other => check("recover-reattach", false, format!("decision={other:?}")),
    }
    match mgr2.reconcile("wf-nobind").expect("reconcile nobind") {
        RecoveryDecision::CleanFailed { .. } => {
            let row = mgr2.get_workflow("wf-nobind").expect("get").expect("row");
            check(
                "recover-cleanfailed",
                WorkflowState::from_i32(row.state) == Some(WorkflowState::Failed),
                format!("row={row:?}"),
            );
        }
        other => check("recover-cleanfailed", false, format!("decision={other:?}")),
    }
    match mgr2.reconcile("wf-done").expect("reconcile done") {
        RecoveryDecision::AlreadyTerminal { .. } => check("recover-terminal", true, String::new()),
        other => check("recover-terminal", false, format!("decision={other:?}")),
    }
    check(
        "recover-unknown",
        mgr2.reconcile("nope").is_err(),
        "unknown reconciled".to_string(),
    );

    let store = Storage::open(&db).expect("open store");
    let sessions = SessionManager::new(&store);
    sessions
        .bind("wf-r", "ps-1", Some("resume-9"))
        .expect("bind");
    let got = sessions.lookup("wf-r").expect("lookup").expect("binding");
    check(
        "session-roundtrip",
        got.provider_session_id == "ps-1" && got.resume_pointer.as_deref() == Some("resume-9"),
        format!("binding={got:?}"),
    );
    check(
        "session-unknown-none",
        sessions.lookup("nope").expect("lookup unknown").is_none(),
        "phantom binding".to_string(),
    );
    drop(mgr2);
    drop(store);
    let store2 = Storage::open(&db).expect("reopen store");
    let sessions2 = SessionManager::new(&store2);
    check(
        "session-restart",
        sessions2
            .lookup("wf-r")
            .expect("lookup2")
            .map(|b| b.provider_session_id)
            == Some("ps-1".to_string()),
        "binding lost across reopen".to_string(),
    );

    let mut router = InputRouter::new(&store2);
    check(
        "router-first",
        router.deliver("wf-r", "in-1", "hello").expect("deliver") == RouteOutcome::Delivered,
        "first not delivered".to_string(),
    );
    check(
        "router-duplicate",
        router.deliver("wf-r", "in-1", "hello").expect("redeliver") == RouteOutcome::Duplicate,
        "repeat not dropped".to_string(),
    );
    check(
        "router-counts",
        router.delivered_for("wf-r") == 1 && router.duplicates_for("wf-r") == 1,
        format!("counts={:?}", router.totals()),
    );
    check(
        "router-cross-workflow",
        router.deliver("wf-nobind", "in-1", "x").expect("cross") == RouteOutcome::Delivered,
        "uuid leaked across workflows".to_string(),
    );
    check(
        "router-unknown",
        router.deliver("nope", "in-9", "x").is_err(),
        "unknown accepted".to_string(),
    );
    let (d, u) = router.forget_workflow("wf-r");
    check(
        "router-forget",
        (d, u) == (1, 1),
        format!("forgot=({d},{u})"),
    );
    check(
        "router-still-duplicate",
        router
            .deliver("wf-r", "in-1", "hello")
            .expect("after forget")
            == RouteOutcome::Duplicate,
        "old uuid resurrected".to_string(),
    );

    let _ = std::fs::remove_dir_all(&dir);
    let failures = unsafe { FAILURES };
    if failures == 0 {
        println!("E2E-EXEC GREEN");
    } else {
        println!("E2E-EXEC RED failures={failures}");
        std::process::exit(1);
    }
}
