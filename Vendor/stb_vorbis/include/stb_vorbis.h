//
//  stb_vorbis.h
//  Aural
//
//  Public header for the vendored stb_vorbis single-file decoder (see ../UPSTREAM.md for the
//  pinned commit). stb_vorbis.c supports being included with only its declarations visible via
//  STB_VORBIS_HEADER_ONLY, which is what makes this file safe for Swift's Clang importer: the
//  compiled definitions live in one place only, stb_vorbis_impl.c.
//

#ifndef AURAL_STB_VORBIS_H
#define AURAL_STB_VORBIS_H

// Keep this in sync with stb_vorbis_impl.c: STB_VORBIS_NO_STDIO removes the FILE*-based open
// functions from both the declarations Swift sees here and the definitions compiled there, so
// the two translation units agree on the available surface (Spotty never reads Vorbis from a
// FILE*; audio bytes arrive over the network into memory).
#ifndef STB_VORBIS_NO_STDIO
#define STB_VORBIS_NO_STDIO
#endif

#define STB_VORBIS_HEADER_ONLY
#include "../stb_vorbis.c"
#undef STB_VORBIS_HEADER_ONLY

#endif // AURAL_STB_VORBIS_H
