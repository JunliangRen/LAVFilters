# Local FFmpeg patches

Base FFmpeg revision: `aaaf9481ca02e1394bf93a301df5b94ae1bb2cf5`.
Source repository: https://github.com/JunliangRen/FFmpeg

`cuvid-sequence-framerate.patch` fixes the output rate reported by FFmpeg's
CUVID decoder after another sequence callback for an existing decoder.
The callback restores the source cadence and applies the effective
deinterlacing multiplier before an existing decoder can return early.
When sequence timing is absent, the default path uses its separately stored,
undoubled caller rate or latest valid sequence rate. Repeated callbacks
therefore cannot multiply an already doubled output rate again.
Progressive sequences and frame-rate output retain the source cadence.
FIFO sizing retains its separate multiplier.

The patch also uses overflow-safe rational rescaling for the first second-field
timestamp. A DirectShow packet timebase of `1/10000000` overflows the original
32-bit multiplication for rates such as `60000/1001`, shortening that field's
initial offset after opening or seeking. Later offsets in the default mode
retain their 64-bit timestamp difference. A missing or invalid frame rate or
packet timebase returns `AVERROR_INVALIDDATA` instead of dividing by zero,
allowing LAV's existing decode error handler to fall back to software.

The new `dynamic_deint` option is disabled by default. LAV's FFmpeg CUVID
backend enables it to keep an adaptive CUDA decoder and its reference
pictures alive while switching between weave, one output per picture, and
one output per field. Woven pictures bypass adaptive processing through
the mapping parameters while retaining their original interlace flags.
Each queued picture records its processing parameters, repeat-field count,
and output rate. Mixed queues count actual decode surfaces and reserve room
for two fields. Live second-field timestamps use the current picture's
snapshotted output interval, including after opening, seeking, cadence
changes, and pictures with repeated fields.

In this opt-in mode, Auto preserves each picture's progressive flag and
outputs progressive pictures once rather than splitting an interlaced
sequence's progressive pictures into two fields. MPEG-2 and H.264 repeated
fields establish the original LAV CUVID backend's two-picture soft-telecine
protection window. Those pictures retain single-picture output and stable
automatic processing field order. Progressive sequences continue bypassing
adaptive processing even when they contain repeated fields. Each unsplit
repeated picture retains its original top-field-first display flag, separately
from the stable field selection used for soft-telecine adaptive mapping.
The default-disabled `aggressive_deint` option
processes progressive pictures in an interlaced sequence except during this
window and for VC-1. `force_deint` explicitly processes progressive pictures
and overrides the soft-telecine suppression. Unsplit pictures retain their
nonnegative `AVFrame.repeat_pict`, so LAV can preserve the typical soft
telecine repeated-field duration. Split outputs clear `repeat_pict` and
divide the source picture's complete display interval, including its
positive repeat count, between the two outputs.

The `lav.cuvid.deinterlaced` frame metadata is set to `1` for each dynamically
queued picture that actually used adaptive processing and `0` for a woven
picture. It is overwritten after frame properties and copyback are complete,
with allocation errors propagated. LAV reads this output snapshot instead of
the current setting so queued hardware-processed fields are not processed
again after a live switch to software deinterlacing.

`deint_field_order` accepts `-1` for bitstream order, `0` for bottom field
first, or `1` for top field first. These live options have no effect when
`dynamic_deint` is disabled. Opaque CUARRAY output rejects live processing;
the LAV backend uses CPU copyback. Supported live modes are weave and
adaptive, with the CUDA decoder remaining adaptive throughout playback.

The optional `deint_framerate` rational (default `0/1`) overrides the
encoded source rate only in live mode. LAV supplies the container rate for
MPEG-4 when known because CUVID can report a different sequence rate.
`deint_framerate_fallback` also defaults to `0/1` and supplies a known
container cadence only when valid sequence timing is absent. The override
takes precedence, followed by valid sequence timing, the fallback, and the
initial caller rate. Each output picture derives its own single/field cadence
from this source rate; a missing H.264 VUI rate does not force software
fallback when its container rate is known.

Both `build_ffmpeg.sh` and `build_ffmpeg_msvc.sh` check and apply this exact
patch before configuring or building, including quick builds. They use
`git apply --ignore-space-change` without changing the index. A successful
reverse check detects an already-applied patch. If neither check succeeds,
the build stops before configuration. Other local source changes are kept;
changes that conflict with these hunks require manual reconciliation.

The patch and this file use CRLF line endings. Application to a clean
CRLF copy of the pinned source, repeated reverse checking, and exact
comparison with the intended patched source were verified. Preview build
provenance must identify the base revision and this local patch's SHA256;
the unchanged submodule gitlink alone does not identify the patched build.
