# nv-codec-headers

Pinned upstream release: n13.0.19.1
Pinned upstream commit: 88fee5c37318c991a8762d423530f91681e32e3a
Video Codec SDK API version: 13.0.19
Upstream package version: 13.0.19.1.2

Upstream project: https://code.ffmpeg.org/FFmpeg/nv-codec-headers
Official mirror: https://github.com/FFmpeg/nv-codec-headers
Pinned source: https://github.com/FFmpeg/nv-codec-headers/tree/88fee5c37318c991a8762d423530f91681e32e3a

The five files in include/ffnvcodec, README and ffnvcodec.pc.in are copied
from the pinned commit. Only line endings are normalized to CRLF. Each
header retains its original MIT-style copyright and permission notice;
LICENSE collects those notices for convenient redistribution.

lib/pkgconfig/ffnvcodec.pc is a local relocatable package description.
Its include directory uses pcfiledir directly because LAV's MinGW build
sets the prefix variable to an architecture-specific dependency folder.
The same headers work for both Win32 and x64 builds.

The build scripts use these headers to enable FFmpeg's CUDA, CUVID and
NVDEC support. These are driver API declarations with dynamic loading;
no CUDA Toolkit, nvcc, CUDA runtime DLL, import library or nonfree build
flag is needed for decoding. The header package also contains the NVENC
API declarations because FFmpeg's configure check requires them; LAV's
encoder-disabled build does not enable NVENC encoders.

Upstream documents NVIDIA Windows drivers 570.0 or newer for this SDK.
Actual decode support is checked at runtime for the selected GPU, codec,
chroma format, bit depth and dimensions. In particular, compiling the
SDK 13.0 4:2:2 paths does not add 4:2:2 decode capability to older GPUs.
