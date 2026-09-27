//! `calcar-connect` binary: serve the agent connection manager.
//!
//! Usage: `calcar-connect --config <path> [--port <n>]`. The port flag
//! overrides the config file for one boot (E2E picks a free port this
//! way); everything else comes from the file.

#![deny(warnings)]

use std::path::PathBuf;

use calcar_connect::{ConnectConfig, ConnectServer};

fn main() -> std::process::ExitCode {
    match run() {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("calcar-connect: {message}");
            std::process::ExitCode::from(1)
        }
    }
}

fn run() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    let mut config_path: Option<PathBuf> = None;
    let mut port_override: Option<u16> = None;
    let mut index = 1;
    while index < args.len() {
        match args[index].as_str() {
            "--config" => {
                index += 1;
                config_path = Some(PathBuf::from(
                    args.get(index).ok_or("--config needs a path")?,
                ));
            }
            "--port" => {
                index += 1;
                port_override = Some(
                    args.get(index)
                        .ok_or("--port needs a value")?
                        .parse::<u16>()
                        .ok()
                        .filter(|port| *port >= 1)
                        .ok_or("--port must be 1..=65535")?,
                );
            }
            other => return Err(format!("unknown argument {other}")),
        }
        index += 1;
    }
    let path = config_path.ok_or("usage: calcar-connect --config <path> [--port <n>]")?;
    let mut config = ConnectConfig::load(&path)
        .map_err(|error| format!("config {}: {error}", path.display()))?;
    if let Some(port) = port_override {
        config.port = port;
    }
    let server = ConnectServer::new(config).map_err(|error| format!("startup: {error}"))?;
    server.run().map_err(|error| format!("serve: {error}"))
}
