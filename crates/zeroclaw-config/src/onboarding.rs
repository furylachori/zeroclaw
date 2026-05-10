//! Onboarding wizard surface — a *wizard* is the ordered set of
//! [`Section`]s the operator walks to reach a working install.
//!
//! Every fact about a section (its enum variant, its on-the-wire key,
//! its UI shape, its help blurb, its position in the wizard) lives in
//! ONE table — the [`sections!`] invocation below. The macro expands
//! that table into the [`Section`] enum, every per-variant `match`
//! helper, and the [`ONBOARDING_WIZARD`] const, so adding a section is
//! exactly one row, no hand-listed variant set anywhere else.
//!
//! Consumers (CLI runtime, gateway, dashboard) dispatch off this enum;
//! drift is a compile error.

use serde::{Deserialize, Serialize};

/// UI rendering shape for a wizard section. Drives picker / form dispatch
/// on both the `/onboard` wizard and the `/config` explorer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "schema-export", derive(schemars::JsonSchema))]
#[serde(rename_all = "snake_case")]
pub enum SectionShape {
    /// `<section>` renders a schema-driven form with no picker step.
    DirectForm,
    /// `<section>.<alias>` map of structured entries; the section page
    /// shows an alias list with `+ Add` and clicking an alias opens its
    /// schema form.
    OneTierAliasMap,
    /// `<section>.<type>.<alias>` two-tier map. Picker chooses `<type>`,
    /// alias-list step chooses `<alias>`, then the schema form opens.
    TypedFamilyMap,
    /// Single non-alias choice (memory backend, tunnel provider). Picker
    /// flips a top-level field, then the schema form for the chosen
    /// backend/provider renders.
    BackendPicker,
}

/// Single source of truth for every onboarding section. Each row maps
/// 1:1 to a wizard step; adding/removing a section is one row here and
/// every consumer's `match` either compiles cleanly or fails with an
/// exhaustiveness error pointing at exactly what needs an arm.
///
/// Order in this invocation is the canonical wizard order — structural
/// sections first, agents last (RFC #5890).
macro_rules! sections {
    (
        $(
            $variant:ident => {
                key:   $key:literal,
                shape: $shape:ident,
                help:  $help:expr $(,)?
            }
        ),+ $(,)?
    ) => {
        /// One onboarding step. The variant ordering follows the
        /// `sections!` macro invocation, which is the canonical wizard
        /// order; [`ONBOARDING_WIZARD`] is generated from the same
        /// table, so the two can never drift.
        ///
        /// With the `clap` feature on, this enum doubles as the
        /// `zeroclaw onboard <section>` clap subcommand — no separate
        /// mirror enum in the binary crate.
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
        #[cfg_attr(feature = "schema-export", derive(schemars::JsonSchema))]
        #[cfg_attr(feature = "clap", derive(clap::Subcommand))]
        #[serde(rename_all = "snake_case")]
        pub enum Section {
            $(
                // Both clap (`--help`) and our runtime `help()` method
                // need the same blurb; emit it once as a doc comment so
                // the two surfaces share a single string per variant.
                #[doc = $help]
                #[cfg_attr(feature = "clap", command(name = $key))]
                $variant
            ),+
        }

        impl Section {
            /// Stable on-the-wire key — appears as the TOML top-level
            /// prefix (`model_providers.<type>.<alias>`), the
            /// `/onboard/<key>` URL segment, and the `SectionInfo.key`
            /// field returned by the gateway.
            #[must_use]
            pub const fn as_str(self) -> &'static str {
                match self { $( Self::$variant => $key ),+ }
            }

            /// Editor shape — the dashboard and the wizard both
            /// dispatch off this so the same component lights up for
            /// the same section in both surfaces.
            #[must_use]
            pub const fn shape(self) -> SectionShape {
                match self { $( Self::$variant => SectionShape::$shape ),+ }
            }

            /// Per-section help blurb — single source of truth for
            /// the copy shown above the section's picker / form on
            /// every surface (CLI `ui.note(...)`, TUI heading,
            /// dashboard `SectionInfo.help`).
            #[must_use]
            pub const fn help(self) -> &'static str {
                match self { $( Self::$variant => $help ),+ }
            }

            /// Parse a stable wire key. Returns `None` for keys that
            /// aren't part of the onboarding wizard. Named `from_key`
            /// rather than `from_str` so clippy doesn't flag it as
            /// confusable with `std::str::FromStr` (parse failure is
            /// `None`, not `Err(_)`).
            #[must_use]
            pub fn from_key(s: &str) -> Option<Self> {
                match s {
                    $( $key => Some(Self::$variant), )+
                    _ => None,
                }
            }
        }

        /// The onboarding wizard: an ordered slice of [`Section`]s
        /// walked during `/onboard`. Generated from the same `sections!`
        /// table that defines the enum, so the order encodes
        /// dependencies (structural sections first, agents last) and
        /// the variant list can never drift from the const list.
        pub const ONBOARDING_WIZARD: &[Section] = &[ $( Section::$variant ),+ ];
    };
}

sections! {
    Workspace => {
        key:   "workspace",
        shape: DirectForm,
        help:  "Where ZeroClaw stores config, memory, and per-agent state. \
                The default install dir is fine for most setups.",
    },
    ModelProviders => {
        key:   "model_providers",
        shape: TypedFamilyMap,
        help:  "Paste an API key (e.g. `sk-ant-...` for Anthropic, `sk-...` for \
                OpenAI) when prompted. For OAuth-based providers run: \
                `zeroclaw auth login --model-provider <name>`.",
    },
    TtsProviders => {
        key:   "tts_providers",
        shape: TypedFamilyMap,
        help:  "Text-to-speech providers (OpenAI, ElevenLabs, Google, Edge, Piper). \
                Configure one per voice / language; agents reference them by alias.",
    },
    TranscriptionProviders => {
        key:   "transcription_providers",
        shape: TypedFamilyMap,
        help:  "Speech-to-text providers (OpenAI Whisper, Groq, Deepgram, AssemblyAI, \
                Google, local Whisper). Configure one per pipeline; agents reference \
                them by alias.",
    },
    Channels => {
        key:   "channels",
        shape: TypedFamilyMap,
        help:  "Pick which chat platforms ZeroClaw should listen on. You can \
                configure multiple — each channel gets its own alias.",
    },
    Memory => {
        key:   "memory",
        shape: BackendPicker,
        help:  "Persistent memory backend. SQLite is the default; pick `none` to \
                disable long-term recall entirely.",
    },
    Hardware => {
        key:   "hardware",
        shape: DirectForm,
        help:  "Optional: hardware peripherals (Arduino, STM32, GPIO, etc.). \
                Skip if you don't need them.",
    },
    Tunnel => {
        key:   "tunnel",
        shape: BackendPicker,
        help:  "Optional: expose your gateway over the public internet via Cloudflare \
                or ngrok. Pick `none` to keep it localhost-only.",
    },
    // Personality is intentionally NOT a wizard section in v0.8.0 —
    // markdown personality files live per-agent and surface inside the
    // agent edit form (RFC #5890).
    Agents => {
        key:   "agents",
        shape: OneTierAliasMap,
        help:  "An agent binds a model provider, profiles, bundles, and channels \
                into one dispatchable unit. Add one per persona; reuse the same \
                alias across channels to share state.",
    },
}

impl std::fmt::Display for Section {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Index of `section` in [`ONBOARDING_WIZARD`].
#[must_use]
pub fn wizard_index(section: Section) -> usize {
    ONBOARDING_WIZARD
        .iter()
        .position(|s| *s == section)
        .expect("every Section variant is enumerated in ONBOARDING_WIZARD")
}

/// Canonical-order index for a wire key, or `None` if the key isn't a
/// wizard section. Used by gateway / dashboard sort comparators that
/// take string keys from the HTTP layer.
#[must_use]
pub fn wizard_index_for_key(key: &str) -> Option<usize> {
    Section::from_key(key).map(wizard_index)
}

/// True when `key` parses as a wizard section.
#[must_use]
pub fn is_wizard_section(key: &str) -> bool {
    Section::from_key(key).is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Round-trip every entry in the canonical wizard. `from_key`,
    /// `as_str`, and `ONBOARDING_WIZARD` are all generated from the
    /// same `sections!` row, so this test exercises the table — adding
    /// a row that breaks any of them fails here without listing
    /// variants by hand.
    #[test]
    fn wizard_round_trips() {
        for s in ONBOARDING_WIZARD {
            assert_eq!(Section::from_key(s.as_str()), Some(*s), "{s} round-trip");
            assert_eq!(wizard_index(*s), {
                ONBOARDING_WIZARD.iter().position(|x| x == s).unwrap()
            });
        }
        assert_eq!(Section::from_key("gateway"), None);
        assert_eq!(Section::from_key("not_a_section"), None);
    }
}
