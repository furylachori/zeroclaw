# Fork Release Workflow

This fork uses a simplified release workflow (`.github/workflows/release-fork.yml`)
that builds a single x86_64-linux-gnu binary and publishes it as a GitHub Release.

## How to release

### Option A: Push a tag

```bash
git tag v0.8.0-beta-2
git push origin v0.8.0-beta-2
```

Any tag matching `v*` triggers the workflow — beta, rc, and stable tags all work.

### Option B: Manual dispatch

1. Go to **Actions → Release (Fork)** in the GitHub UI.
2. Click **Run workflow**.
3. Enter the version string (e.g. `0.8.0-beta-2`).

## What gets built

1. **Web dashboard** — compiled via `cargo web build`, produces `web/dist/`.
2. **Binary** — `zeroclaw` for `x86_64-unknown-linux-gnu`, built with `--profile ci`
   (thin LTO, 16 codegen units) and bundled features:
   `channel-matrix`, `channel-lark`, `whatsapp-web`.
3. **GitHub Release** — the tarball, `SHA256SUMS`, and `install.sh` are attached as
   release assets.

## Downloading binaries

The tarball is available from the fork's **Releases** page:

```
https://github.com/<your-org>/zeroclaw/releases/tag/<tag>
```

## Note on `install.sh`

The `install.sh --prebuilt` script still points to the **upstream** repository by
default. Users of this fork should download release assets directly from the fork's
Releases page instead of relying on `install.sh --prebuilt`.
