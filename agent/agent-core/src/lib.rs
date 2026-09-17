//! agent-core: foundation types for the Calcar agent.
//!
//! This crate is a skeleton. It intentionally contains no networking,
//! process management, credentials handling, or workflow execution.

use std::fmt;

/// Runtime subsystems the agent will eventually provide.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Subsystem {
    /// Device identity and pairing with the owner device.
    Identity,
    /// Network communication with trusted devices.
    Network,
    /// Workflow lifecycle management.
    WorkflowRuntime,
}

impl Subsystem {
    pub const ALL: [Subsystem; 3] = [
        Subsystem::Identity,
        Subsystem::Network,
        Subsystem::WorkflowRuntime,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Subsystem::Identity => "identity",
            Subsystem::Network => "network",
            Subsystem::WorkflowRuntime => "workflow runtime",
        }
    }
}

impl fmt::Display for Subsystem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

/// Basic facts about the machine the agent runs on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlatformInfo {
    pub os: &'static str,
    pub arch: &'static str,
    pub family: &'static str,
}

pub fn platform_info() -> PlatformInfo {
    PlatformInfo {
        os: std::env::consts::OS,
        arch: std::env::consts::ARCH,
        family: std::env::consts::FAMILY,
    }
}

/// Reports which subsystems are not implemented.
///
/// Every subsystem is unimplemented in this skeleton; the function exists so
/// callers enumerate them through one place instead of hardcoding strings.
pub fn unimplemented_subsystems() -> Vec<Subsystem> {
    Subsystem::ALL.to_vec()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn platform_info_is_populated() {
        let info = platform_info();
        assert!(!info.os.is_empty());
        assert!(!info.arch.is_empty());
        assert!(!info.family.is_empty());
    }

    #[test]
    fn all_subsystems_report_unimplemented() {
        assert_eq!(unimplemented_subsystems(), Subsystem::ALL.to_vec());
    }

    #[test]
    fn subsystem_names_are_unique() {
        let mut names: Vec<_> = Subsystem::ALL.iter().map(|s| s.name()).collect();
        names.sort();
        names.dedup();
        assert_eq!(names.len(), Subsystem::ALL.len());
    }
}
