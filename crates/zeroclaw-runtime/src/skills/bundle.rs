//! Bundle-side helpers: directory resolution, default paths, and bundle
//! summaries surfaced to the dashboard/CLI/TUI.
//!
//! All bundle-directory defaulting goes through [`resolve_directory`] — the
//! `<install>/shared/skills/<alias>/` default lives here only, so changing it
//! is a one-place edit.

use std::path::{Path, PathBuf};

use zeroclaw_config::schema::Config;

/// Lightweight bundle view returned by [`crate::skills::service::SkillsService::list_bundles`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BundleSummary {
    pub alias: String,
    pub directory: PathBuf,
    pub include: Vec<String>,
    pub exclude: Vec<String>,
}

#[derive(Debug, thiserror::Error)]
pub enum BundleError {
    #[error("skill bundle '{0}' is not configured")]
    UnknownBundle(String),

    #[error(
        "skill-bundle directory '{path}' escapes the shared workspace at '{shared}'; bundles must stay inside `<install>/shared/`"
    )]
    DirectoryEscapesShared { path: String, shared: String },

    #[error(
        "skill-bundle directory '{path}' is already claimed by bundle '{other}'; each bundle must own a unique directory"
    )]
    DirectoryCollision { path: String, other: String },
}

/// Resolve the on-disk directory for a configured bundle, applying the default
/// when `[skill-bundles.<alias>].directory` is unset.
///
/// Default = `<install>/shared/skills/<alias>/`. Absolute paths configured by
/// the user pass through verbatim; relative paths are resolved against the
/// install root.
pub fn resolve_directory(
    config: &Config,
    install_root: &Path,
    alias: &str,
) -> Result<PathBuf, BundleError> {
    let bundle = config
        .skill_bundles
        .get(alias)
        .ok_or_else(|| BundleError::UnknownBundle(alias.to_string()))?;

    let configured = bundle
        .directory
        .as_deref()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty());

    let path = match configured {
        Some(raw) => {
            let candidate = PathBuf::from(raw);
            if candidate.is_absolute() {
                candidate
            } else {
                install_root.join(candidate)
            }
        }
        None => default_directory(install_root, alias),
    };
    Ok(path)
}

/// Canonical default location for a bundle's skills.
pub fn default_directory(install_root: &Path, alias: &str) -> PathBuf {
    install_root.join("shared").join("skills").join(alias)
}

/// Reject directories that escape `<install>/shared/`. Used at scaffold and
/// at config-validate time so a bad value never reaches disk.
pub fn validate_directory(path: &Path, install_root: &Path) -> Result<(), BundleError> {
    let shared = install_root.join("shared");
    let normalized = normalize_path(path);
    let shared_normalized = normalize_path(&shared);
    if !normalized.starts_with(&shared_normalized) {
        return Err(BundleError::DirectoryEscapesShared {
            path: normalized.display().to_string(),
            shared: shared_normalized.display().to_string(),
        });
    }
    Ok(())
}

/// Verify no two bundles' directories collide. Run at config-load time.
pub fn validate_uniqueness(config: &Config, install_root: &Path) -> Result<(), BundleError> {
    let mut seen: Vec<(String, PathBuf)> = Vec::with_capacity(config.skill_bundles.len());
    for alias in config.skill_bundles.keys() {
        let dir = resolve_directory(config, install_root, alias)?;
        let normalized = normalize_path(&dir);
        if let Some((other, _)) = seen.iter().find(|(_, p)| p == &normalized) {
            return Err(BundleError::DirectoryCollision {
                path: normalized.display().to_string(),
                other: other.clone(),
            });
        }
        seen.push((alias.clone(), normalized));
    }
    Ok(())
}

/// Lexical path normalization — strips `.` and resolves `..` components
/// without touching the filesystem. Sufficient for "stays inside `shared/`"
/// reasoning where neither path may exist yet.
fn normalize_path(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        use std::path::Component;
        match component {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use zeroclaw_config::schema::SkillBundleConfig;

    fn cfg_with_bundle(alias: &str, directory: Option<&str>) -> Config {
        let mut cfg = Config::default();
        cfg.skill_bundles.insert(
            alias.to_string(),
            SkillBundleConfig {
                directory: directory.map(String::from),
                ..Default::default()
            },
        );
        cfg
    }

    #[test]
    fn unset_directory_defaults_to_shared_skills_alias() {
        let cfg = cfg_with_bundle("alpha", None);
        let root = Path::new("/tmp/install");
        let resolved = resolve_directory(&cfg, root, "alpha").unwrap();
        assert_eq!(resolved, root.join("shared").join("skills").join("alpha"));
    }

    #[test]
    fn empty_directory_string_is_treated_as_unset() {
        let cfg = cfg_with_bundle("alpha", Some("   "));
        let root = Path::new("/tmp/install");
        let resolved = resolve_directory(&cfg, root, "alpha").unwrap();
        assert_eq!(resolved, root.join("shared").join("skills").join("alpha"));
    }

    #[test]
    fn relative_directory_resolves_against_install_root() {
        let cfg = cfg_with_bundle("alpha", Some("shared/skills/custom"));
        let root = Path::new("/tmp/install");
        let resolved = resolve_directory(&cfg, root, "alpha").unwrap();
        assert_eq!(resolved, root.join("shared/skills/custom"));
    }

    #[test]
    fn absolute_directory_passes_through() {
        let cfg = cfg_with_bundle("alpha", Some("/abs/path"));
        let resolved = resolve_directory(&cfg, Path::new("/tmp/install"), "alpha").unwrap();
        assert_eq!(resolved, PathBuf::from("/abs/path"));
    }

    #[test]
    fn unknown_bundle_errors() {
        let cfg = Config::default();
        let err = resolve_directory(&cfg, Path::new("/tmp/install"), "alpha").unwrap_err();
        assert!(matches!(err, BundleError::UnknownBundle(a) if a == "alpha"));
    }

    #[test]
    fn validate_directory_accepts_paths_inside_shared() {
        let root = Path::new("/tmp/install");
        let path = root.join("shared/skills/alpha");
        validate_directory(&path, root).unwrap();
    }

    #[test]
    fn validate_directory_rejects_paths_outside_shared() {
        let root = Path::new("/tmp/install");
        let path = PathBuf::from("/etc/passwd");
        let err = validate_directory(&path, root).unwrap_err();
        assert!(matches!(err, BundleError::DirectoryEscapesShared { .. }));
    }

    #[test]
    fn validate_directory_rejects_dotdot_escape() {
        let root = Path::new("/tmp/install");
        let path = root.join("shared/../etc");
        let err = validate_directory(&path, root).unwrap_err();
        assert!(matches!(err, BundleError::DirectoryEscapesShared { .. }));
    }

    #[test]
    fn uniqueness_passes_for_distinct_default_directories() {
        let mut cfg = Config::default();
        cfg.skill_bundles
            .insert("alpha".into(), SkillBundleConfig::default());
        cfg.skill_bundles
            .insert("beta".into(), SkillBundleConfig::default());
        validate_uniqueness(&cfg, Path::new("/tmp/install")).unwrap();
    }

    #[test]
    fn uniqueness_rejects_two_bundles_pointing_at_same_dir() {
        let mut cfg = Config::default();
        cfg.skill_bundles.insert(
            "alpha".into(),
            SkillBundleConfig {
                directory: Some("shared/skills/shared-pool".into()),
                ..Default::default()
            },
        );
        cfg.skill_bundles.insert(
            "beta".into(),
            SkillBundleConfig {
                directory: Some("shared/skills/shared-pool".into()),
                ..Default::default()
            },
        );
        let err = validate_uniqueness(&cfg, Path::new("/tmp/install")).unwrap_err();
        assert!(matches!(err, BundleError::DirectoryCollision { .. }));
    }
}
