# cet (vendored)

This directory contains a bundled copy of the upstream mod loader. It is the install-time
source of truth: install.cmd extracts directly from here and never reaches out to the network.
Refresh manually with `pixi run update-deps`, then commit.

## Snapshot

- Asset: `cet_1.37.1.zip`
- Tag: `v1.37.1`
- Upstream URL: https://github.com/maximegmd/CyberEngineTweaks/releases/download/v1.37.1/cet_1.37.1.zip
- SHA-256: `1855017796a27f518199f5b7d7210ef1db7a5c5f0af468c68e04e6e666ad248c`
- Source: github

Do not edit this directory by hand. Run `pixi run update-deps` to refresh.
