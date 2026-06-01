# FORK.md — ZeroClaw Fork (furylachori/zeroclaw)

Fork of [zeroclaw-labs/zeroclaw](https://github.com/zeroclaw-labs/zeroclaw) with
two additions: **audio auto-download for Telegram voice messages** and an
**audit logger wired into the agent runtime**.

> **For AI coding assistants:** read this file before touching any code in this
> fork. It explains what changed, where, and how to work with upstream.

---

## What Changed

### 1. Audio auto-download (`process_audio_without_transcription`)

Voice messages in Telegram are no longer gated behind transcription enablement.
Two new config fields on `[channels.telegram]`:

| Field | Type | Default | Effect |
|---|---|---|---|
| `process_audio_without_transcription` | `bool` | `false` | Saves the audio file to `workspace/telegram_files/` without calling a transcription provider |
| `save_transcribed_audio` | `bool` | `false` | After successful transcription, also saves the original audio file |

When neither is enabled (default), behavior is unchanged — transcription-only.

**Key files:**
- `crates/zeroclaw-channels/src/telegram.rs`
  - `try_parse_voice_message()` — branching logic
  - `save_audio_file()` — workspace file writer
  - `handle_audio_only_save()` — save path handler
  - `download_file()` — Content-Length guard added
- `crates/zeroclaw-config/src/schema.rs` — new fields on `TelegramConfig`

### 2. Audit logger wiring

The audit logger (`AuditLogger`) is now instantiated at daemon startup and threaded
through every agent execution layer, so policy violations and tool executions are
logged to a local file.

**Key files:**
- `crates/zeroclaw-config/src/security/audit.rs` — `AuditLogger`
  - `write_mutex`, `sync_mode`, symlink guard, path canonicalization
- `crates/zeroclaw-config/src/policy.rs` — `AuditSink` trait + `SecurityPolicy::for_agent` (3-arg)
- `crates/zeroclaw-runtime/src/daemon/mod.rs` — `DaemonSubsystems.audit_logger`
- `crates/zeroclaw-runtime/src/agent/loop_.rs` — `run_tool_call_loop` (29 args)
- `crates/zeroclaw-runtime/src/agent/tool_execution.rs` — `execute_one_tool` (with audit logging)
- `crates/zeroclaw-channels/src/orchestrator/mod.rs` — `ChannelRuntimeContext.audit_logger`
- `src/main.rs` — `AuditLogger` instantiation before daemon start

**Signature changes requiring call-site updates:**

| Function | Package | New arg |
|---|---|---|
| `SecurityPolicy::for_agent(config, alias, audit_logger)` | zeroclaw-config | `Option<Arc<dyn AuditSink>>` |
| `run_tool_call_loop(...)` (29 args) | zeroclaw-runtime | `audit_logger: Option<Arc<AuditLogger>>` |
| `execute_one_tool(...)` | zeroclaw-runtime | `audit_logger: Option<Arc<AuditLogger>>` |
| `ChannelRuntimeContext { ... }` | zeroclaw-channels | `audit_logger: None` |

Every call site in test code and production code has been updated. When adding new
call sites, pass `None` for `audit_logger` unless the call site is inside the
daemon/agent runtime where the logger is available.

---

## Git Workflow

Simple: work on `master` directly, rebase from upstream before every work session.
No feature branches unless you have two things in progress at the same time.

### Remote setup

```bash
git remote add upstream https://github.com/zeroclaw-labs/zeroclaw.git
git remote -v   # origin should point to your fork
```

### Before every work session

```bash
git fetch upstream
git rebase upstream/master
```

That's it. Your `master` becomes a fast-forward of upstream + your local commits.
Commit and push as normal. No branch juggling needed.

### Concurrent work (optional)

If you have two features in progress simultaneously, use a feature branch for one:

```bash
git checkout -b feat/my-feature
# ... work, commit ...
git push origin feat/my-feature
```

When the feature is done, rebase it on the latest `master` and merge or squash-merge.

### What NOT to do

- **Do not `git merge` upstream into your branch.** Always rebase.
- **Do not skip the pre-session rebase.** Small conflicts every few days are better than one big merge headache.
- **Do not `git push --force` to shared branches** (only to your own local branches).

---

## Validation

```bash
# Build check (run before every push)
cargo check 2>&1 | tail -5

# Test (run after any code change)
cargo test --package zeroclaw-config --package zeroclaw-runtime --package zeroclaw-channels --features channel-telegram 2>&1 | grep -E "test result|FAILED|error\[" | tail -10

# Full quality gate
./dev/ci.sh all
```

---

## Upstream Sync Checklist

When rebasing from upstream, check for:

- [ ] New fields added to `TelegramConfig` → add `process_audio_without_transcription: false` and `save_transcribed_audio: false`
- [ ] `SecurityPolicy::for_agent` signature changed → add `None` as 3rd argument
- [ ] `run_tool_call_loop` signature changed → add `None` as last argument
- [ ] `execute_one_tool` signature changed → add `None` as last argument
- [ ] New test fixtures constructing `TelegramConfig` → add the two bool fields
- [ ] New test fixtures constructing `ChannelRuntimeContext` → add `audit_logger: None`

---

## Architecture Map for Fork Changes

| Change | Read first | Why |
|---|---|---|
| Telegram voice handling | `crates/zeroclaw-channels/src/telegram.rs`, `docs/book/src/channels/voice.md` | Inbound media pipeline |
| Audio file storage | `crates/zeroclaw-channels/src/telegram.rs` → `save_audio_file()` | Workspace layout |
| Transcription pipeline | `crates/zeroclaw-channels/src/transcription.rs` | Provider dispatch |
| Audit logger | `crates/zeroclaw-config/src/security/audit.rs` | File-based policy audit |
| AuditSink trait | `crates/zeroclaw-config/src/policy.rs` | Trait for pluggable sinks |
| SecurityPolicy for_agent | `crates/zeroclaw-config/src/policy.rs` | 3-arg signature |
| Agent loop threading | `crates/zeroclaw-runtime/src/agent/loop_.rs` | 29-arg run_tool_call_loop |

---

## Config Reference

```toml
[channels.telegram]
enabled = true
bot_token = "..."
# Save voice files without transcription (no API cost)
process_audio_without_transcription = true

# After transcription, also save the original audio
save_transcribed_audio = true

[security.audit]
enabled = true                     # must be true for audit logging
path = "audit.log"               # relative to data_dir
sync_mode = true                  # fsync after every write
```

---

## Filing Issues Against This Fork

Open issues at https://github.com/furylachori/zeroclaw/issues.
Label fork-specific bugs with `fork-only`.