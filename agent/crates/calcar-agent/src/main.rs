mod doctor;

use clap::{Parser, Subcommand};
use std::process::ExitCode;

/// Calcar agent. Runs workflows on this computer and reports to the backend.
#[derive(Debug, Parser)]
#[command(name = "calcar-agent", version)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Run preflight checks: OS, ConPTY, DPAPI, storage migrate, port bind.
    Doctor,
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match cli.command {
        Command::Doctor => match doctor::run() {
            Ok(report) => {
                for check in &report.checks {
                    let mark = if check.ok { "ok  " } else { "FAIL" };
                    println!("{mark}  {:<12} {}", check.name, check.detail);
                }
                if report.all_ok() {
                    ExitCode::SUCCESS
                } else {
                    ExitCode::from(1)
                }
            }
            Err(error) => {
                eprintln!("doctor failed to run: {error}");
                ExitCode::from(1)
            }
        },
    }
}
