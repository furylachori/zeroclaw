//! Staged dream mutations — the "pending" review surface.
//!
//! When `audit_mode` is enabled (default), proposed memory mutations from a
//! dream cycle are written to `dream_pending.json` in the workspace directory
//! instead of being applied directly. The user can review and promote them
//! via `zeroclaw dream promote`.

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::Path;

const PENDING_FILENAME: &str = "dream_pending.json";

/// A staged set of proposed memory mutations from a dream cycle.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DreamPending {
    /// Proposed Core memory insights to be created.
    pub insights: Vec<StagedInsight>,
    /// Memory keys proposed for deletion (stale/outdated).
    pub proposed_prunes: Vec<String>,
    /// When this pending set was generated.
    pub timestamp: DateTime<Utc>,
    /// Human-readable summary of what the dream cycle found.
    pub summary: Option<String>,
}

/// A single proposed Core memory insight.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StagedInsight {
    /// The insight text to be stored as a Core memory.
    pub content: String,
    /// Computed importance score.
    pub importance: f64,
}

impl DreamPending {
    /// Persist pending mutations to `dream_pending.json`.
    pub fn save(&self, workspace_dir: &Path) -> Result<()> {
        let path = workspace_dir.join(PENDING_FILENAME);
        let json =
            serde_json::to_string_pretty(self).context("dream pending: failed to serialize")?;
        std::fs::write(&path, json)
            .with_context(|| format!("dream pending: failed to write {}", path.display()))?;
        Ok(())
    }

    /// Load pending mutations, if any exist.
    pub fn load(workspace_dir: &Path) -> Result<Option<DreamPending>> {
        let path = workspace_dir.join(PENDING_FILENAME);
        if !path.exists() {
            return Ok(None);
        }

        let data = std::fs::read_to_string(&path)
            .with_context(|| format!("dream pending: failed to read {}", path.display()))?;
        let pending: DreamPending = serde_json::from_str(&data)
            .with_context(|| format!("dream pending: failed to parse {}", path.display()))?;

        Ok(Some(pending))
    }

    /// Remove the pending file after promotion or rejection.
    pub fn clear(workspace_dir: &Path) -> Result<()> {
        let path = workspace_dir.join(PENDING_FILENAME);
        if path.exists() {
            std::fs::remove_file(&path)
                .with_context(|| format!("dream pending: failed to remove {}", path.display()))?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pending_roundtrip() {
        let temp = tempfile::tempdir().unwrap();
        let pending = DreamPending {
            insights: vec![StagedInsight {
                content: "User prefers Rust.".into(),
                importance: 0.8,
            }],
            proposed_prunes: vec!["old_key_1".into()],
            timestamp: Utc::now(),
            summary: Some("Quiet day.".into()),
        };

        pending.save(temp.path()).unwrap();
        let loaded = DreamPending::load(temp.path()).unwrap();
        assert!(loaded.is_some());
        let loaded = loaded.unwrap();
        assert_eq!(loaded.insights.len(), 1);
        assert_eq!(loaded.proposed_prunes.len(), 1);
    }

    #[test]
    fn no_pending_returns_none() {
        let temp = tempfile::tempdir().unwrap();
        let loaded = DreamPending::load(temp.path()).unwrap();
        assert!(loaded.is_none());
    }

    #[test]
    fn clear_removes_file() {
        let temp = tempfile::tempdir().unwrap();
        let pending = DreamPending {
            insights: vec![],
            proposed_prunes: vec![],
            timestamp: Utc::now(),
            summary: None,
        };
        pending.save(temp.path()).unwrap();
        assert!(temp.path().join("dream_pending.json").exists());

        DreamPending::clear(temp.path()).unwrap();
        assert!(!temp.path().join("dream_pending.json").exists());
    }
}
