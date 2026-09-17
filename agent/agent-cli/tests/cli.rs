use std::process::Command;

fn bin_path() -> &'static str {
    env!("CARGO_BIN_EXE_calcar-agent")
}

fn run(args: &[&str]) -> (String, String, Option<i32>) {
    let output = Command::new(bin_path())
        .args(args)
        .output()
        .expect("failed to spawn calcar-agent");
    (
        String::from_utf8_lossy(&output.stdout).into_owned(),
        String::from_utf8_lossy(&output.stderr).into_owned(),
        output.status.code(),
    )
}

#[test]
fn version_flag_prints_version_and_exits_zero() {
    let (stdout, stderr, code) = run(&["--version"]);
    assert_eq!(code, Some(0));
    assert!(stdout.trim().starts_with("calcar-agent "));
    assert!(stderr.is_empty());
}

#[test]
fn doctor_lists_platform_and_unimplemented_subsystems() {
    let (stdout, _stderr, code) = run(&["doctor"]);
    assert_eq!(code, Some(0));
    assert!(stdout.contains("os:"));
    assert!(stdout.contains("architecture:"));
    assert!(stdout.contains("identity: not implemented"));
    assert!(stdout.contains("network: not implemented"));
    assert!(stdout.contains("workflow runtime: not implemented"));
}

#[test]
fn unknown_argument_exits_nonzero() {
    let (stdout, stderr, code) = run(&["frobnicate"]);
    assert_ne!(code, Some(0));
    assert!(stdout.is_empty());
    assert!(stderr.contains("unknown argument: frobnicate"));
}

#[test]
fn no_arguments_exits_nonzero_with_usage() {
    let (stdout, stderr, code) = run(&[]);
    assert_ne!(code, Some(0));
    assert!(stdout.is_empty());
    assert!(stderr.contains("USAGE"));
}
