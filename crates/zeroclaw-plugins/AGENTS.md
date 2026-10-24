# zeroclaw-plugins

## What this crate is

WASM plugin host for ZeroClaw. Handles plugin discovery, manifest parsing,
Ed25519 signature verification, and the WIT / direct `wasmtime` execution
bridge. Bridges plugin-exported functions into ZeroClaw's `Tool` and
`Channel` traits so plugins appear as native capabilities to the agent runtime.

## What this crate is allowed to depend on

- `zeroclaw-api` (traits only — `Tool`, `Channel`, `ToolResult`)
- `wasmtime` (Component Model host)
- `wasmtime-wasi` and `wasmtime-wasi-http` (WASI Preview 2 host support)
- `ring` (Ed25519 signatures)
- `serde`, `serde_json`, `toml`, `toml_edit` (serialization)
- `jsonschema` (manifest-owned plugin config-contract validation; network resolvers disabled)
- `tokio` (async bridging via `spawn_blocking`)
- `tracing` (logging)
- `anyhow`, `thiserror` (error handling)

Do not add dependencies on specific tools, channels, providers, or config
schemas. This crate knows how to run plugins, not what they do.

## Extension points

- **New WIT interfaces:** Add or revise the versioned interface under
  `wit/v0/`, then update the matching component bridge. Treat WIT edits as
  compatibility-sensitive architecture changes.
- **New host imports:** Add them through `component.rs` or the per-world
  linker for the relevant bridge, not as ad hoc Extism-style JSON host
  functions. Gate the import on a `PluginPermission` variant (add to `lib.rs`
  if needed). HTTP support is wired through WASI HTTP when
  `PluginPermission::HttpClient` is granted.
- **New capability bridges:** Add alongside `wasm_tool.rs` and
  `wasm_channel.rs` (e.g., `wasm_memory.rs` for memory backend plugins).
- **New permissions:** Add variants to `PluginPermission` in `lib.rs`.

## What does NOT belong here

- Concrete tool or channel implementations (those go in `zeroclaw-tools` or
  `zeroclaw-channels`, or in a WASM plugin)
- Plugin business logic (that belongs in the plugin's own crate)
- Config schema definitions (those go in `zeroclaw-config`)
- Plugin registry client or distribution (future separate crate)

## Related ADRs

- ADR-003: historical Extism plugin bootstrap, superseded by ADR-009
- ADR-009: WIT components and direct `wasmtime` plugin execution

## Repository artifact policy

Reviewers MUST flag and request rework when a PR commits a non-code artifact without an explicit justification in that originating PR identifying the file and its required purpose. Passing tests or calling a file "evidence" does not waive this rule.

Generated evidence, logs, traces, screenshots, recordings, dumps, and reports belong in the originating PR or issue, NEVER in the repository. Store bulky artifacts in Google Drive and link them from that PR or issue. Do not commit those artifacts as documentation or fixtures to evade this policy.

Source code and tests belong in the repository. Any minimal fixture, documentation, or configuration genuinely required by the implementation must have an explicit file-and-purpose justification in the originating PR; retain only what is required. If that justification is absent, request rework rather than accepting the artifact.

This AGENTS.md policy update is explicitly requested by the repository owner.
