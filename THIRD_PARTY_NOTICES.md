# Third-party notices

## Spotifly playback bridge and authentication support

Portions of `Backend/spotty-playback` and `Sources/Spotty/Spotify` are adapted from
[Spotifly](https://github.com/ralph/Spotifly), commit
`35991ac25a04aa14f8839d88f46129da6c6b59c0`. The Connect command and metadata request shapes are
adapted from commit `bcb522675e9657599faa007c531c2159e506246f`.

Copyright (c) 2026 Ralph von der Heyden. Used under the MIT License.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## librespot

The Rust bridge links upstream [librespot](https://github.com/librespot-org/librespot), pinned to
commit `a1b66d3c8a14e55a9572a9e17467150dca618c9a`, including its unmodified `connect` crate.
librespot is MIT licensed and carries the copyright below.

Copyright (c) 2015 Paul Lietar

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

## Transitive Rust dependencies

The playback artifact report is generated from the exact target graph recorded in
`Backend/spotty-playback/Cargo.lock`:

```sh
python3 Scripts/generate-playback-notices.py \
  --target aarch64-apple-darwin \
  --output <artifact-notices-directory>
```

The generated directory contains `ThirdPartyNotices.md`, a machine-readable `manifest.json`, and
the complete UTF-8 license and notice texts under `licenses/`. The current Apple Silicon graph
contains 269 third-party packages and 188 unique full license texts. The manifest records each
package's lockfile checksum or pinned git revision, source location, license expression, and the
SHA-256 and byte count for every bundled text. The generator fails closed when a source package has
no discoverable license text and no explicit pinned upstream override.
