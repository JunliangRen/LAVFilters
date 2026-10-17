# AVS software decoder dependencies

`build_avs.sh x64|x86` builds the AVS dependencies for the matching MinGW
toolchain. Exact revisions are recorded in `avs-versions.txt`; no moving branch
head or external FFmpeg binary is used. `LAV_AVS_DEPS_DIR` selects the dependency
source/cache directory. Installed libraries and headers go to `thirdparty/64`
or `thirdparty/32`, as used by the opt-in `avs` FFmpeg build.

## AVS2 8-bit and 10-bit

The existing 8-bit backend remains at the official
<https://github.com/pkuvcl/davs2> revision
`b41cf117452e2d73d827f02d3e30aa20f1c721ac`. Only the 10-bit backend uses
<https://github.com/xatabhk/davs2-10bit> at revision
`21d64c8f8e36af71fc7a488cd6f789c86cdd1200`, which contains the high-depth pixel,
transform and reconstruction implementation. Both retain davs2's GPL license
(`COPYING.davs2`). The script requires the two normalized public headers to be
identical before building either archive, then installs the official header.
This preserves the established 8-bit reconstruction behavior while keeping the
public structure layout consistent for the 10-bit extension.

The two pinned implementations are compiled separately:

- `libdavs2.a`: normal 8-bit build, existing `davs2_decoder_*` API.
- `libdavs2_10.a`: 10-bit build, six `lav_davs2_10_decoder_*` entrypoints declared
  in `davs2_10.h`, using the same `davs2_*_t` argument types.

`davs2-patches/fixed-10bit-state.patch` is applied only to the 10-bit source:
it permits the existing 10-bit configure path, initializes the global pixel
limits to compile-time 10-bit constants, and rejects sequences with another
internal bit depth. It also replaces an unqualified `min` in the high-depth
SIMD code with the existing `DAVS2_MIN` macro for MinGW builds, and removes
dispatch to an AVX2 ALF function which the fork declares but does not implement.
The existing SSE4 ALF path and C fallback remain available. The official
8-bit decoder's 13-entry frame-rate table and range clamp are also ported to
the high-depth fork, avoiding its unchecked access to an eight-entry table.
DPB cleanup handles a failed buffer allocation without dereferencing a null
buffer and resets the stored buffer count.
The fork
otherwise changes these globals while parsing
each sequence, which would allow decoders with different depths to interfere.
The FFmpeg wrapper chooses the matching archive per decoder context from the
sequence's internal encoding precision. Main10 streams with 8-bit internal
precision still use the 8-bit archive.

GNU `objcopy --redefine-syms` namespaces every globally defined symbol in the
10-bit archive, including C++, weak symbols and assembly definitions. Undefined
runtime imports retain their normal names. The build verifies zero global
symbol overlap between the archives and verifies all six high-depth entrypoints
for the target architecture. A C link test references all six APIs of both
archives, checks their full static dependency closure, and opens/closes one
decoder of each depth. The `davs2.pc` file links both archives and closes the
static C++/thread runtime dependencies.

The script reverses only its exact known dependency patch before reusing a
checkout, then requires that tracked source be clean. It aborts for unrelated
source edits. Source checkouts, configure/build logs and symbol maps remain in
the cache for inspection. Installed text files use CRLF line endings.

This integration is software decoding. Decoder support alone does not establish
real-time 4K50 performance, renderer behavior or audio/video synchronization.

## AVS3

uavs3d remains pinned separately and builds with `COMPILE_10BIT=1` for its
existing baseline 8/10-bit support. Its license is `COPYING.uavs3d`.
