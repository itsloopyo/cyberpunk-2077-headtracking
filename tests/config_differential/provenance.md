The Lua oracle is modules/settings.lua at f9862bf38b0ecb1aa5734b8af164909cb2db6996.
SHA-256: 7f535710bd8c26b9d067d3bfd64407b46af88c60bf4ca4ea4ab0d99dbe149e4f.
The native legacy reader preserves that reader's field defaults, type checks,
numeric clamping and enum validation. The oracle is test-only.

published_settings.lua is the reader from v1.3.3. data/ contains config.json
from every v* tag through v1.3.3. The comparison records these intervening changes:
de822b5 removed ads_mode, 03e94f5 removed decouple_diag_clean_cam, and f9862bf
added TrueFreeLook. All other current fields match v1.3.3 in the corpus.
Migration additionally removes the reticle preference and saved master-toggle
bookkeeping, restores the saved tracking mode, and lets the unchanged 0.05
downward limit follow the shared 0.20 default.

JSON for Modern C++ 3.12.0 supplies the native JSON decoder. Its vendored header
SHA-256 is aaf127c04cb31c406e5b04a63f1ae89369fccde6d8fa7cdda1ed4f32dfc5de63.
