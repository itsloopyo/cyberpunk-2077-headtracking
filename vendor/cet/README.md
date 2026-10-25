# cet (vendored)

This directory contains a bundled copy of the upstream mod loader. It is the install-time
source of truth: install.cmd extracts directly from here and never reaches out to the network.
Refresh manually with `pixi run update-deps`, then commit.

## Snapshot

- Asset: `cet_1_38_0.zip`
- Tag: `v1.38.0`
- Commit: `ed706fb8518712ffedf6b566e52873b257bc49fb`
- Upstream URL: https://github.com/maximegmd/CyberEngineTweaks/releases/download/v1.38.0/cet_1_38_0.zip
- SHA-256: `6da2e91b07d5ea9dd4aa32145b2c2920a976abee481854976e2ae82169b612e1`
- Fetched at: 2026-10-25T20:57:46.7108011+00:00
- Source: github

Do not edit this directory by hand. Run ``pixi run package`` (or CI release) to refresh.
