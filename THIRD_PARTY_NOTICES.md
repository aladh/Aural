# Third-party notices

## Spotifly playback bridge and authentication support

Portions of `Backend/aural-playback` and `Sources/Aural/Spotify` are adapted from
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
commit `9c7d75615fc093bdcbdb29adbce3fed38c531852`. librespot is MIT licensed.

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

The source repository does not vendor or publish a precompiled Rust archive. Building Spotty fetches
the exact transitive dependency graph recorded in `Backend/aural-playback/Cargo.lock`. Each fetched
package carries its own license metadata and license files.

Anyone distributing a compiled Spotty binary must generate, review, and bundle the notices and
license texts required by the exact locked dependency graph and build target. The notices above
cover Spotty's adapted source and primary upstream; they are not a complete binary-distribution
license report.
