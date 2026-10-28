# zeroclaw-runtime — Transitional Holding Crate

This crate is a **temporary holding area**, not a permanent home. It contains 126K LOC of subsystems extracted from the original monolith that have not yet been decomposed into their final crate structure.

Do not add new functionality here. The RFC's Phase 2-4 roadmap defines the decomposition plan: agent loop, gateway, channels orchestrator, daemon, cron, security, observability, hardware, TUI, skills, and doctor will each be extracted into dedicated crates or converted to WASM plugins.

**Stability tier:** Experimental — no stability guarantee. Decomposition begins at v0.8.0.

## Repository artifact policy

Reviewers MUST flag and request rework when a PR commits a non-code artifact without an explicit justification in that originating PR identifying the file and its required purpose. Passing tests or calling a file "evidence" does not waive this rule.

Generated evidence, logs, traces, screenshots, recordings, dumps, and reports belong in the originating PR or issue, NEVER in the repository. Store bulky artifacts in Google Drive and link them from that PR or issue. Do not commit those artifacts as documentation or fixtures to evade this policy.

Source code and tests belong in the repository. Any minimal fixture, documentation, or configuration genuinely required by the implementation must have an explicit file-and-purpose justification in the originating PR; retain only what is required. If that justification is absent, request rework rather than accepting the artifact.

This AGENTS.md policy update is explicitly requested by the repository owner.
