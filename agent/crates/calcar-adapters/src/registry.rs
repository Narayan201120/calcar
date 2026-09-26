//! Enum dispatch over providers. New provider is one new file, one
//! variant below, and the arms the compiler then demands. No provider
//! name string ever leaves this module: callers match on `Provider`.
use calcar_events::Provider;

use super::traitdef::{
    AdapterError, AdapterSnapshot, ApprovalDecision, ApprovalOutcome, Capabilities,
    ProviderAdapter, ProviderEvent, SpawnRequest,
};

use crate::{claude, codex, generic, opencode};

/// One of the known provider backends. Exhaustive on purpose.
pub enum Adapter {
    Generic(generic::GenericAdapter),
    Opencode(opencode::OpencodeAdapter),
    Claude(claude::ClaudeAdapter),
    Codex(codex::CodexAdapter),
}

/// Build the adapter for a provider. Unspecified has no adapter.
pub fn for_provider(provider: Provider) -> Result<Adapter, AdapterError> {
    match provider {
        Provider::Generic => Ok(Adapter::Generic(generic::GenericAdapter::new())),
        Provider::Opencode => Ok(Adapter::Opencode(opencode::OpencodeAdapter::new())),
        Provider::Claude => Ok(Adapter::Claude(claude::ClaudeAdapter::new())),
        Provider::Codex => Ok(Adapter::Codex(codex::CodexAdapter::new())),
        Provider::Unspecified => Err(AdapterError::Unsupported),
    }
}

impl ProviderAdapter for Adapter {
    fn name(&self) -> &'static str {
        match self {
            Adapter::Generic(a) => a.name(),
            Adapter::Opencode(a) => a.name(),
            Adapter::Claude(a) => a.name(),
            Adapter::Codex(a) => a.name(),
        }
    }

    fn provider(&self) -> Provider {
        match self {
            Adapter::Generic(a) => a.provider(),
            Adapter::Opencode(a) => a.provider(),
            Adapter::Claude(a) => a.provider(),
            Adapter::Codex(a) => a.provider(),
        }
    }

    fn capabilities(&self) -> Capabilities {
        match self {
            Adapter::Generic(a) => a.capabilities(),
            Adapter::Opencode(a) => a.capabilities(),
            Adapter::Claude(a) => a.capabilities(),
            Adapter::Codex(a) => a.capabilities(),
        }
    }

    fn spawn(&mut self, req: SpawnRequest) -> Result<(), AdapterError> {
        match self {
            Adapter::Generic(a) => a.spawn(req),
            Adapter::Opencode(a) => a.spawn(req),
            Adapter::Claude(a) => a.spawn(req),
            Adapter::Codex(a) => a.spawn(req),
        }
    }

    fn inject(&mut self, input: &[u8]) -> Result<(), AdapterError> {
        match self {
            Adapter::Generic(a) => a.inject(input),
            Adapter::Opencode(a) => a.inject(input),
            Adapter::Claude(a) => a.inject(input),
            Adapter::Codex(a) => a.inject(input),
        }
    }

    fn respond_approval(
        &mut self,
        request_id: &str,
        decision: ApprovalDecision,
    ) -> Result<ApprovalOutcome, AdapterError> {
        match self {
            Adapter::Generic(a) => a.respond_approval(request_id, decision),
            Adapter::Opencode(a) => a.respond_approval(request_id, decision),
            Adapter::Claude(a) => a.respond_approval(request_id, decision),
            Adapter::Codex(a) => a.respond_approval(request_id, decision),
        }
    }

    fn stop(&mut self) -> Result<(), AdapterError> {
        match self {
            Adapter::Generic(a) => a.stop(),
            Adapter::Opencode(a) => a.stop(),
            Adapter::Claude(a) => a.stop(),
            Adapter::Codex(a) => a.stop(),
        }
    }

    fn drain(&mut self) -> Vec<ProviderEvent> {
        match self {
            Adapter::Generic(a) => a.drain(),
            Adapter::Opencode(a) => a.drain(),
            Adapter::Claude(a) => a.drain(),
            Adapter::Codex(a) => a.drain(),
        }
    }

    fn snapshot(&self) -> AdapterSnapshot {
        match self {
            Adapter::Generic(a) => a.snapshot(),
            Adapter::Opencode(a) => a.snapshot(),
            Adapter::Claude(a) => a.snapshot(),
            Adapter::Codex(a) => a.snapshot(),
        }
    }
}
