//! Process-local registry of active per-agent sessions.
//!
//! [`super::delete_agent`] consults this to refuse deletion while an
//! agent has an in-flight session: the alias's workspace dir must
//! not disappear under a running agent loop's feet.
//!
//! Sessions are registered via [`register_session`], which returns a
//! [`SessionGuard`]; the guard decrements the per-alias count when it
//! drops, so the registration is RAII-safe across panics. Spawn sites
//! (interactive CLI, single-shot run, channel orchestrator's
//! `process_message`, cron's `run_agent_job`) hold the guard for the
//! duration of the run.
//!
//! Process-local is enough: a `delete_agent` call comes in via the
//! same daemon process the agent loops run in, so the in-memory
//! counter sees them. A separate `zeroclaw` invocation against the
//! same install (rare admin path) won't see in-flight sessions —
//! that's the operator's hazard window, mirrored by the running-out-
//! of-disk-space class of risk every long-running daemon shares.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

type Counts = Arc<Mutex<HashMap<String, usize>>>;

fn registry() -> &'static Counts {
    static REGISTRY: OnceLock<Counts> = OnceLock::new();
    REGISTRY.get_or_init(|| Arc::new(Mutex::new(HashMap::new())))
}

/// Increment the active-session count for `alias` and return a guard
/// that decrements on drop. Safe to call from any thread.
#[must_use = "the SessionGuard must be held for the lifetime of the agent run; \
              dropping it eagerly will let `delete_agent` pull the rug"]
pub fn register_session(alias: impl Into<String>) -> SessionGuard {
    let alias = alias.into();
    {
        let mut counts = registry().lock().expect("session registry mutex poisoned");
        *counts.entry(alias.clone()).or_insert(0) += 1;
    }
    SessionGuard { alias }
}

/// Active session count for `alias` at the moment of the call.
#[must_use]
pub fn active_sessions_for(alias: &str) -> usize {
    registry()
        .lock()
        .expect("session registry mutex poisoned")
        .get(alias)
        .copied()
        .unwrap_or(0)
}

/// RAII guard returned by [`register_session`]. Drops the per-alias
/// active count when the guard goes out of scope; safe across panics
/// (the `Drop` impl is the only path that decrements).
pub struct SessionGuard {
    alias: String,
}

impl Drop for SessionGuard {
    fn drop(&mut self) {
        let mut counts = match registry().lock() {
            Ok(g) => g,
            // Mutex poisoned — process is in undefined state already;
            // skip the decrement rather than panicking on drop.
            Err(_) => return,
        };
        if let Some(n) = counts.get_mut(&self.alias) {
            *n = n.saturating_sub(1);
            if *n == 0 {
                counts.remove(&self.alias);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // The registry is process-global; each test uses a unique alias
    // so they don't collide when the test runner runs them in
    // parallel.

    #[test]
    fn register_session_increments_and_drop_decrements() {
        let alias = "session_registry_alpha";
        assert_eq!(active_sessions_for(alias), 0);
        {
            let _g = register_session(alias);
            assert_eq!(active_sessions_for(alias), 1);
        }
        assert_eq!(
            active_sessions_for(alias),
            0,
            "drop must decrement back to zero"
        );
    }

    #[test]
    fn nested_sessions_are_counted() {
        let alias = "session_registry_beta";
        assert_eq!(active_sessions_for(alias), 0);
        let g1 = register_session(alias);
        let g2 = register_session(alias);
        assert_eq!(active_sessions_for(alias), 2);
        drop(g1);
        assert_eq!(active_sessions_for(alias), 1);
        drop(g2);
        assert_eq!(active_sessions_for(alias), 0);
    }

    #[test]
    fn unknown_alias_returns_zero() {
        assert_eq!(active_sessions_for("session_registry_unknown_gamma"), 0);
    }
}
