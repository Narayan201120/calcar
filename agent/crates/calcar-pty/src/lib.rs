//! ConPTY manager for the Calcar agent. PLAN P4 slice 3.
//!
//! One PTY per workflow. Each workflow runs inside a Windows Job Object so a
//! kill ends the whole process tree. Stdout and stderr pump through bounded
//! channels to the adapter parse step, input routes back to PTY stdin, and
//! idle means blocked reads with no polling.
//!
//! Windows only. The gate runs on Win10 and Win11.

use thiserror::Error;

#[derive(Debug, Error)]
pub enum PtyError {
    #[error("pty slice not implemented yet: {0}")]
    Unimplemented(&'static str),
    #[error("pty error: {0}")]
    Other(String),
}

/// Handle to one workflow PTY plus its job object. Dropping it must close the
/// conpty and terminate every process in the job.
pub struct WorkflowPty {
    _private: (),
}

/// Spawn configuration for one workflow process tree.
#[derive(Debug, Clone)]
pub struct SpawnConfig {
    pub argv: Vec<String>,
    pub working_dir: Option<String>,
    pub env: Vec<(String, String)>,
}

impl WorkflowPty {
    /// Spawn `argv` inside a fresh ConPTY attached to a fresh job object.
    pub fn spawn(_config: SpawnConfig) -> Result<Self, PtyError> {
        Err(PtyError::Unimplemented("slice 3"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Placeholder so the workspace stays green before slice 3 lands.
    #[test]
    fn spawn_is_unimplemented() {
        let config = SpawnConfig {
            argv: vec!["true".into()],
            working_dir: None,
            env: vec![],
        };
        assert!(matches!(
            WorkflowPty::spawn(config),
            Err(PtyError::Unimplemented("slice 3"))
        ));
    }
}
