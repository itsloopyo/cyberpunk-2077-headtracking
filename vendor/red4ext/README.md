# red4ext (vendored)

This directory contains a bundled copy of the upstream mod loader. It is the install-time
source of truth: install.cmd extracts directly from here and never reaches out to the network.
Refresh manually with `pixi run update-deps`, then commit.

## Snapshot

- Asset: `red4ext-1.30.0.zip`
- Tag: `v1.30.0`
- Upstream URL: https://github.com/WopsS/RED4ext/releases/download/v1.30.0/red4ext-1.30.0.zip
- SHA-256: `3a72225c9d2c46c99f4a4159d952b9d24366357c2423eb7ea255c84e9e11c0b0`
- Source: github

Do not edit this directory by hand. Run `pixi run update-deps` to refresh.
