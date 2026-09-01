# ZeroClaw Fork — furylachori/zeroclaw

This fork tracks [`zeroclaw-labs/zeroclaw`](https://github.com/zeroclaw-labs/zeroclaw) `master` and adds **one feature**: Telegram audio auto-download.

## Fork policy

**`origin/master` = `zeroclaw-labs/master` + this fork's audio auto-download feature, and nothing else.**

No silent divergences. No undocumented removals. Every commit on `master` must be either an upstream merge/rebase or a verifiable fork-only change.

## The fork's only feature

### Telegram audio auto-download

When an inbound Telegram voice or audio message arrives and **no transcription backend is configured**, the bot downloads the audio to disk and exposes the file path to the agent as message content. The agent then invokes whichever registered transcription skill/tool it has available (OpenAI Whisper, Groq, a user-supplied custom skill, etc.) to convert the audio before interpreting it as a user command.

Upstream's behavior in the same situation is to **silently drop** the voice message (transcription is gated on having a configured STT backend).

#### Config

```toml
[channels.telegram.<alias>]
# ... required: enabled, bot_token, ...

# When true, voice/audio messages are downloaded and saved to
# <workspace>/telegram_files/ even when no transcription backend is
# configured. The agent then invokes a registered transcription
# skill/tool on the saved file. Default: false.
process_audio_without_transcription = true

# (Reserved for future use) When true, transcribed audio files are
# saved to the workspace alongside the transcript. Default: false.
# save_transcribed_audio = false
```

Both fields live on `TelegramConfig` and serialize with `#[serde(default)]`, so existing configs continue to load unchanged.

#### How it works

1. Telegram delivers a voice/audio message.
2. `try_parse_voice_message` sees `transcription.is_none()` + `process_audio_without_transcription == true` + `workspace_dir.is_some()` and dispatches to `handle_audio_only_save`.
3. Authorization gates (`is_any_user_allowed`, `check_media_mention_gate`) run identically to upstream's transcription path — auto-download does **not** bypass peer allowlists or `mention_only`.
4. `get_file_path` resolves the Telegram CDN path; `download_file` fetches the bytes. A pre-flight `file_size` check and a post-flight `audio_data.len()` check enforce `TELEGRAM_MAX_FILE_DOWNLOAD_BYTES` (20 MB).
5. The file is written to `<workspace>/telegram_files/{voice|audio}_{chat_id}_{message_id}.{ext}` where `ext` is derived from the MIME type (`audio/ogg` → `oga`, `audio/mpeg` → `mp3`, `audio/mp4` → `m4a`, etc.) and falls back to the Telegram file_path extension or `oga`.
6. The agent receives a `ChannelMessage` with content `[Audio: <filename>] /full/path/to/file`. The agent's LLM uses whatever registered transcription skill/tool matches the file path to convert and interpret.
7. **No caching**: `voice_chats` and `voice_transcriptions` are intentionally not updated in auto-download mode — the agent sees a file reference and handles it as a one-shot document, not as a conversation voice thread.

#### Files touched

| File | Change |
|---|---|
| `crates/zeroclaw-config/src/schema.rs` | Add `process_audio_without_transcription` and `save_transcribed_audio` to `TelegramConfig` + `Default` impl. |
| `crates/zeroclaw-channels/src/telegram.rs` | Add `process_audio_without_transcription: bool` field, `with_process_audio_without_transcription()` builder, new `handle_audio_only_save()` method, and dispatch branch at top of `try_parse_voice_message`. |
| `crates/zeroclaw-channels/src/orchestrator/mod.rs` | Wire `.with_process_audio_without_transcription(...)` in `build_channel_by_id` and `collect_configured_channels`; plus `TelegramConfig` test literals updated for the two new fields. |
| `crates/zeroclaw-runtime/src/daemon/mod.rs` | `TelegramConfig` test literals updated for the two new fields. |
| `crates/zeroclaw-runtime/src/integrations/registry.rs` | `TelegramConfig` test literal updated for the two new fields. |
| `src/config/mod.rs` | `TelegramConfig` test literal updated for the two new fields. |

No changes to: `runtime/agent/*`, `runtime/skills/*`, `runtime/security/*`, `providers/*`, `discord/*`, `Cargo.toml`, `Cargo.lock`, or any other upstream surface. The "agent invokes a registered skill/tool on the saved file" capability is upstream's existing skill loader — `load_skills_for_agent(&config.agent_workspace_dir(...), ...)` already runs at session start.

## Keeping `master` in sync with upstream

```bash
# From a clean tree on master:
git fetch zeroclaw-labs master
git rebase zeroclaw-labs/master    # fast-forward or trivial conflicts in TelegramConfig

# After rebase:
cargo fmt --all -- --check
cargo clippy --all-targets --features ci-all -- -D warnings
cargo test --workspace --exclude zeroclaw-desktop
./dev/ci.sh dry-check              # advisory scan + audit must remain green
```

The port is intentionally surgical so rebase conflicts are limited to:
- `crates/zeroclaw-config/src/schema.rs` around `TelegramConfig`
- `crates/zeroclaw-channels/src/telegram.rs` near `try_parse_voice_message`

If a rebase introduces a conflict elsewhere, **stop** — that means this fork has drifted from its single-feature scope and the diff needs to be split before continuing.

## What this fork deliberately drops

The previous fork state (`furylachori/zeroclaw` at tag `fork/pre-reset-backup`) bundled several undocumented changes under commit `a565d51c5 "feat: audio auto-download, audit logger wiring, skills path fix"` and three follow-up commits. On 2026-07-08 we reset `master` to `zeroclaw-labs/master` and re-applied only the audio auto-download feature. The following items were dropped because they were either undocumented upstream regressions, redundant with upstream's later work, or accidental commits:

- `audit_logger` plumbing through `run_tool_call_loop` / `SecurityPolicy::for_agent` (upstream owns audit)
- Audit hardening in `crates/zeroclaw-runtime/src/security/audit.rs` (write_mutex, path-traversal guard, symlink guard — upstream brought these in differently)
- `format_error_chain` deletion in `crates/zeroclaw-providers/src/lib.rs` (regression; upstream restored it)
- Error-formatting regressions in `crates/zeroclaw-providers/src/{anthropic,compatible,openrouter}.rs`
- `audit_logger: Option<Arc<dyn AuditSink>>` field on `SecurityPolicy` (dropped with the audit plumbing)
- `sync_mode` config field on `AuditConfig` (upstream has its own audit governance via `docs/maintainers/audit-policy.md`)
- Homebrew onboarding code in `src/main.rs` (`runtime_dir_env_is_explicit`, `resolve_homebrew_onboard_config_dir`, `apply_homebrew_onboard_config_dir*`) — upstream's Homebrew onboarding is back
- `memory clear` subcommand deletion in `src/memory/cli.rs` — upstream's CLI is intact
- File deletions: `docs/book/src/channels/signal.md`, `docs/book/src/channels/whatsapp.md`, `docs/book/src/maintainers/project-board-contract.json`, `docs/book/src/tools/python-skills.md`
- `setup.bat` UX simplifications (dropping `--no-default-features` minimal-build option, binary-size echo, build-command echo)
- `AGENTS.md` and `.claude/skills/*` doc tweaks (upstream is canonical)
- Stray files committed at repo root: `telegram_voice_tests.rs` (122 lines, wrong path) and `tests_content_length_guard.txt` (107 lines, wrong extension)
- `scripts/{upgrade,rollback}-{fork,user}.sh` VPS ops scripts (not tied to the audio feature; can be re-added as a separate commit if needed)
- `.github/workflows/release-fork.yml` (x86_64-linux-gnu release pipeline — only useful if the fork ships its own binaries)
- `FORK-RELEASE.md`, old `FORK.md`, old `CHANGELOG-next.md` (replaced by this file)

If any of these turn out to be intentional fork policy, restore them as **separate, single-purpose commits** with their own rationale documented here. Do not re-bundle them under the audio auto-download commit.

## Backups

The pre-reset fork state is preserved at tag `fork/pre-reset-backup` (commit `9f42ac0eb`). Reference it for archaeology, but do not base new work on it.