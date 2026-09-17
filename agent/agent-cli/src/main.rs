use std::process::ExitCode;

use agent_core::{platform_info, unimplemented_subsystems};

const VERSION: &str = env!("CARGO_PKG_VERSION");

const USAGE: &str = "\
calcar-agent - Calcar agent (foundation, not functional)

USAGE:
    calcar-agent <COMMAND>

COMMANDS:
    --version   Print the agent version
    doctor      Report platform info and unimplemented subsystems
";

fn main() -> ExitCode {
    match std::env::args().nth(1).as_deref() {
        Some("--version") => {
            println!("calcar-agent {VERSION}");
            ExitCode::SUCCESS
        }
        Some("doctor") => {
            run_doctor();
            ExitCode::SUCCESS
        }
        Some(arg) => {
            eprintln!("error: unknown argument: {arg}");
            eprint!("{USAGE}");
            ExitCode::from(2)
        }
        None => {
            eprint!("{USAGE}");
            ExitCode::from(2)
        }
    }
}

fn run_doctor() {
    let info = platform_info();
    println!("Calcar agent doctor");
    println!("version: {VERSION}");
    println!("os: {}", info.os);
    println!("architecture: {}", info.arch);
    println!("family: {}", info.family);
    println!();
    println!("Not implemented (this build is a skeleton, not a working agent):");
    for subsystem in unimplemented_subsystems() {
        println!("  - {subsystem}: not implemented");
    }
}
