# Upstream pin

- Source: https://github.com/nothings/stb/blob/master/stb_vorbis.c
- Pinned commit: `1ee679ca2ef753a528db5ba6801e1067b40481b8` (Sean Barrett, 2021-07-12,
  "update version numbers")
- stb_vorbis version per the file header: `v1.22`
- License: dual public domain (Unlicense) / MIT, see `LICENSE` (copied verbatim from the block at
  the bottom of `stb_vorbis.c`)

`stb_vorbis.c` is vendored unmodified. Do not edit it in place; if a fix is needed, pull a newer
pinned commit instead and update this file.

## Files

- `stb_vorbis.c` — unmodified upstream source, excluded from the `CVorbis` target's compiled
  sources (it is `#include`d by `stb_vorbis_impl.c`, so compiling it directly would duplicate
  every symbol).
- `stb_vorbis_impl.c` — the single compiled translation unit: defines `STB_VORBIS_NO_STDIO` and
  includes `stb_vorbis.c`.
- `include/stb_vorbis.h` — a thin public header. Defines `STB_VORBIS_HEADER_ONLY` before including
  `stb_vorbis.c` so only declarations (no bodies) are visible to Swift's Clang importer, then
  undefines it.

## Refreshing the pin

1. Fetch the latest `stb_vorbis.c` from the URL above.
2. Record the new commit sha/date/message and version line here.
3. Diff against the previous file to confirm nothing but upstream content changed.
4. Re-run the CI gate; nothing else in this vendor directory should need to change.
