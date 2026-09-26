//! Provider adapter contract, P5. Core only sees these types plus the
//! common events in `calcar-events`. Adding a provider is one new file,
//! one `Adapter` variant, and the match arms the compiler demands.
//!
//! Transport rule: adapters spawn over plain pipes today. `interactive`
//! requests route to the ConPTY path once its E2E gate goes green; until
//! then `spawn_pty` reports Unsupported and nothing pretends otherwise.

mod registry;
mod traitdef;

pub mod claude;
pub mod codex;
pub mod generic;
pub mod opencode;
pub mod permission;

pub use permission::PermissionManager;
pub use registry::{for_provider, Adapter};
pub use traitdef::{
    AdapterError, AdapterSnapshot, ApprovalDecision, ApprovalOutcome, Capabilities,
    ProviderAdapter, ProviderEvent, SpawnRequest,
};
