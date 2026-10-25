# red4ext (vendored)

This directory contains a bundled copy of the upstream mod loader. It is the install-time
source of truth: install.cmd extracts directly from here and never reaches out to the network.
Refresh manually with `pixi run update-deps`, then commit.

## Snapshot

- Asset: `red4ext-1.31.0.zip`
- Tag: `v1.31.0`
- Commit: `9f135ac339b00c55a68d06ce7106e960dd82962a`
- Upstream URL: https://github.com/wopss/RED4ext/releases/download/v1.31.0/red4ext-1.31.0.zip
- SHA-256: `b9ae4351f547f90af58dfbf7445d45c55cd5ba24fbee27fb16fb5d91e9df621e`
- Fetched at: 2026-10-25T20:57:47.9325549+00:00
- Source: github

Do not edit this directory by hand. Run ``pixi run package`` (or CI release) to refresh.
