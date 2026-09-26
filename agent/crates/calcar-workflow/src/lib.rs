//! Workflow lifecycle manager: the sole writer of workflow state.
//! PLAN P4, DEC-014, DEC-028. See [`WorkflowManager`] for the API.

mod lifecycle;
mod router;
mod session;

pub use calcar_storage::{StorageError, WorkflowRow};
pub use lifecycle::{LifecycleError, RecoveryDecision, WorkflowManager, WorkflowView};
pub use router::{InputRouter, RouteOutcome};
pub use session::{SessionBinding, SessionManager};
