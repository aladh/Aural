//
//  stb_vorbis_impl.c
//  Spotty
//
//  The single compiled translation unit for the vendored stb_vorbis decoder (see UPSTREAM.md for
//  the pinned commit). stb_vorbis.c is excluded from the CVorbis target's own sources and is
//  compiled only once, here, via #include -- compiling it directly as a second source file would
//  duplicate every symbol it defines.
//

#define STB_VORBIS_NO_STDIO
#include "stb_vorbis.c"
