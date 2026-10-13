# FFmpeg CUVID DirectShow regression

The harness loads the selected package's LAV Splitter and LAV Video through their class-factory exports. It uses runtime configuration, does not register filters or save player settings, and captures actual decoder/device status after every playback segment. Backends 0, 1, and 6 select software, legacy CUVID, and FFmpeg CUVID. The exact FFmpeg CUVID status must be `cuvid (ffmpeg)`; software fallback must report `avcodec`.

Each graph decodes to natural EOS, seeks forward, seeks backward, repeats the forward seek, and replays the whole file. It records frame timestamps, negotiated media AvgTimePerFrame, field flags, dimensions, ordered SHA256, full MD5, actual decoder/device, and hardware support status. NV12/YV12 normalize to yuv420p, P010 to yuv420p10le, P210 to yuv422p10le, Y416 to yuv444p10le, and P016 to yuv420p12le. Padding and high-bit alignment are removed without reducing precision.

From a matching Visual Studio Native Tools prompt, after building the Release DirectShow base classes:

```bat
tests\cuvid-ffmpeg\build.cmd x64
tests\cuvid-ffmpeg\build.cmd x86
```

Prepare references with a standalone FFmpeg that includes libx264, libx265, libvpx-vp9, libaom-av1, FFV1, and the relevant CUVID decoders:

```powershell
tests\cuvid-ffmpeg\prepare-fixtures.ps1 -FFmpeg C:\Windows\ffmpeg.exe
tests\cuvid-ffmpeg\validate-adaptive.ps1 -Platform x64 -Package F:\Repos\LAVFilters\bin_x64 -OutputDirectory bin_build\cuvid-ffmpeg-20261010\adaptive-oracle\x64
tests\cuvid-ffmpeg\validate.ps1 -Platform x64 -Package F:\Repos\LAVFilters\bin_x64 -AdaptiveReportPath bin_build\cuvid-ffmpeg-20261010\adaptive-oracle\x64\validation.json
tests\cuvid-ffmpeg\validate-adaptive.ps1 -Platform x86 -Package F:\Repos\LAVFilters\bin_Win32 -OutputDirectory bin_build\cuvid-ffmpeg-20261010\adaptive-oracle\x86
tests\cuvid-ffmpeg\validate.ps1 -Platform x86 -Package F:\Repos\LAVFilters\bin_Win32 -AdaptiveReportPath bin_build\cuvid-ffmpeg-20261010\adaptive-oracle\x86\validation.json
```

All generated media, references, logs, helpers, and reports default to ignored `bin_build/cuvid-ffmpeg-20261010`. Use a fresh `-OutputDirectory` to retain previous reports. `-OnlyFixtures` narrows the run; `-SkipOldBackend` omits the legacy H264 smoke. The optional second build argument chooses a helper output directory, with `-HarnessPath` selecting it during validation.

Four-second 320x240 testsrc2 fixtures cover H264 B frames, MPEG4 B frames in MP4 and DTS-only AVI fallback, HEVC Main10, HEVC 4:4:4 10-bit, HEVC Main12, VP9, AV1, TFF H264, TFF/BFF MPEG2, HEVC 4:2:2 10-bit fallback on a GPU without that profile, and unsupported FFV1 fallback. Existing official AVS3 fixture evidence is reused when available. FFmpeg CUVID also runs with device 0, an invalid index 999 that should fall back to default selection, and YV12 conversion. Interlaced cases cover weave and hardware adaptive single/double field output. Software cases compare software references; CUVID cases compare standalone CUVID references, including adaptive GPU output. Hardware reference generation uses the installed NVIDIA driver and is separate evidence from the package's DirectShow path.

Progressive H264 also exercises aggressive weave, requiring progressive media/sample flags. Adaptive Force and explicit TFF/BFF overrides retain FFmpeg CUVID. TFF/BFF progressive output compares complete decode/seek pixels and timestamps with separately configured legacy CUVID controls. Force validates GPU status, source frame counts and timestamps, durations, processed sample flags, exact replay, and repeated seeks. The standalone and legacy decoders do not provide an independent pixel oracle for forced progressive filtering. Software controls retain the corresponding software-only settings coverage.

Adaptive processing depends on the packet history supplied after each seek. `validate-adaptive.ps1` first compares the normal graph with a graph containing a test-only compressed-packet tracer; all pixels, timestamps, durations, and field flags must remain identical. It then feeds the exact captured compressed packets, including preroll and the trailing stop packet, to standalone FFmpeg CUVID. Packet timestamps and the first decodable key packet determine the negative preroll alignment. The resulting ordered hashes must match every delivered frame. The report retains compressed packet and stream hashes, packet timestamps, alignment, and standalone output hashes. The main validator requires this passing report to bind the same architecture, helper, and package binaries.

Validation requires native PE/process architecture, actual backend/device, natural EOS, complete frame counts and ordered reference hashes, positive monotonically ordered timestamps, exact full/replay sample durations and negotiated media AvgTimePerFrame, exact replay, repeated-seek pixel/timestamp equality, progressive output flags after adaptive processing, and nonzero low precision bits in high-bit output. For weave and software seeks, output must form an exact contiguous subsequence of full playback and agree with the software control's seek position, counts, and timestamps. Adaptive seeks require the independent packet-history reference described above. Reports bind package, helper, source, manifest, and adaptive reference hashes. These are small synthetic GPU/DirectShow tests. They do not establish renderer compatibility, audio/video sync, real broadcast support, throughput, or sustained playback. The fallback profile expectation is specific to the tested GPU capability.

The packet tracer preserves the splitter's compressed packet boundaries. Arbitrarily fragmented AnnexB or elementary-stream delivery from external filters is outside this suite's coverage.

FFmpeg's default 32-bit and 64-bit MPEG2/MPEG4 software IDCT implementations can produce different exact pixels. `-ArchitectureReferencePath` optionally selects references generated by an independent native AVformat/AVcodec decoder for those four 8-bit software fixtures. Its JSON binds the process architecture, reference executable, candidate DLL/AX files, original fixture manifest, source media, default decoder settings, and each reference hash file. The validator still requires exact full MD5 and ordered frame SHA256; hardware and high-bit references retain the standalone FFmpeg references.

`validate-targeted.ps1` adds the fractional-rate and live-settings regressions without changing the established fixture manifest or its independent pixel references:

```powershell
tests\cuvid-ffmpeg\validate-targeted.ps1 -Platform x64 -Package F:\Repos\LAVFilters\bin_x64 -OutputDirectory bin_build\cuvid-ffmpeg-20261010\targeted\x64
tests\cuvid-ffmpeg\validate-targeted.ps1 -Platform x86 -Package F:\Repos\LAVFilters\bin_Win32 -OutputDirectory bin_build\cuvid-ffmpeg-20261010\targeted\x86
```

It generates a four-second 30000/1001 MPEG2 TFF fixture and requires CUVID adaptive field-rate output to place the first second field at 166833 DirectShow ticks, including whole replay. Every playback/seek segment must retain field cadence; later sample spacing and overlap permit at most one millisecond because Matroska rounds the fixture's packet PTS to that time base. This catches the CUVID first-second-field integer overflow while accepting timestamp quantization.

An eight-second integer-rate MPEG2 TFF fixture exercises live Adaptive Video (frame per field) to Disabled to Adaptive Film (frame per two fields), then returns to Adaptive Video or changes to Force, explicit TFF, or explicit BFF. Each scenario uses one continuously running graph. A test-only compressed-packet gate waits immediately before three key packets, allowing the main thread to change settings while decoding is idle; the graph is never stopped, flushed, or sought between changes. Each output frame records its setting phase and actual decoder. Every one of the 200 encoded display positions must retain one output frame or two contiguous fields, including all transition boundaries. This catches leading B-picture loss from reopening at an MPEG2 open GOP. Stable frames in each phase compare pixels, cadence, negotiated duration, and sample flags with independently started static CUVID graphs. Static interlaced Auto/Force/TFF pixels compare with standalone adaptive CUVID. BFF output compares with its static graph and must differ from TFF, without claiming an independent forced-BFF pixel oracle.

Processed live samples must carry the progressive weave flag. Their negotiated media type can retain a previously advertised interlaced flag under LAV's existing renderer compatibility policy; the test requires an earlier queued weave sample to account for that retained type. Disabled processing uses the same weave pixels and renderer-deinterlacing suppression flags as its static control.

A progressive MPEG2 fixture validates Force's single-rate frame coverage and requires forced double-rate output to emit 200 fields from 100 source pictures. Pixel identity with automatic output is permitted on progressive sources. Progressive and interlaced MPEG4 MP4 fixtures verify forced and ordinary adaptive double-rate hardware output, with 200000-tick sample and media duration beginning at the first output frame. The interlaced case also requires exact field cadence and duration after every seek. The harness mode `adaptive-force-double` selects Force with frame-per-field output. Forced progressive cases do not claim an independent pixel-quality oracle.

For direct harness use, the optional argument after `PACKET_DIRECTORY` selects `cycle`, `force`, `tff`, or `bff`; use `-` for the packet directory when only the live gate is needed. Live runs require backend 6 and initial `adaptive-double`. The ordinary full-pixel and exact-packet regression suite remains the correctness reference for decoded pictures.

`validate-edge.ps1` covers the subsequent rate fallback, default FFmpeg API,
queued processing and soft telecine findings. Build the independent codec probe
after the FFmpeg configuration headers and import libraries are available:

```bat
tests\cuvid-ffmpeg\build.cmd x64 bin_build\cuvid-ffmpeg-20261011\harness\x64
tests\cuvid-ffmpeg\build-probe.cmd x64
```

```powershell
tests\cuvid-ffmpeg\validate-edge.ps1 -Platform x64 -Package F:\Repos\LAVFilters\bin_x64 -OutputDirectory bin_build\cuvid-ffmpeg-20261011\edge\x64
```

Repeat the matching Native Tools build and validation with `x86` and
`bin_Win32`. Fixture mutation uses Python 3's standard library. Generated text
and source files retain CRLF. The reports bind candidate DLL hashes, process
architecture, helper hashes and the actual codec probe DLL paths.

An interlaced H264 fixture has its SPS VUI timing removed while retaining a
25 fps MP4 container. The SPS is changed in its avcC atom while preserving
all atom sizes, original B-picture PTS/CTS and compressed sample payloads.
Five whole/seek/replay segments must remain on the GPU and
retain exact 20 ms field cadence. A separate codec API probe opens `h264_cuvid`
with the default `dynamic_deint=0`, caller framerate 25 fps, and adaptive double
output; it requires 50 fps and a 20 ms first second-field interval. Repeated SPS
headers must not accumulate the rate multiplier.

The soft telecine fixture retains independently encoded progressive MPEG2
frame pictures, changes the sequence to interlaced, and alternates RFF with
valid 3:2 top-field order. Zero B frames keep coded and display order identical.
The ordinary MPEG2 software decoder independently supplies the expected raw
repeat, original top-field order, picture count and 40/60 ms display intervals.
Auto and Aggressive double must retain one output per picture, RFF flags and the original
field order of repeated whole pictures. Force double must retain two fields,
clear their repeat flags, and preserve each complete picture's display span
(20/20 or 30/30 ms). Five playback/seek segments execute all three modes; full and
whole replay check every reference picture and field. A separate stable-TFF
soft telecine variant compares Auto's single adaptive output with standalone
CUVID adaptive single pixels. This reference uses the same field selection as
LAV's soft telecine stability window. It does not assert that adaptive pixels
equal woven pixels or independently judge forced filtering quality.

A progressive-sequence RFF variant verifies that Auto bypasses adaptive
processing, preserves woven pixels and keeps repeat metadata. MPEG2 progressive
sequence RFF can represent more than one repeated field; this case does not
claim to repair LAV's pre-existing common duration treatment of those larger
repeat values. The complete duration regression uses interlaced-sequence RFF1.

Continuous Force hardware-to-weave transitions enable YADIF or BWDIF at an idle
key-packet gate. Every source field must retain exactly one 20 ms sample,
including queued old hardware fields. The first queued fields must preserve
hardware pixels. Stable software output compares with standalone woven CUVID
plus the requested software filter. Each transition runs once without stop,
flush or seek. Disabling an already running software filter is outside this
test's scope. These remain small synthetic headless GPU/DirectShow tests.


Continuous software/hardware transitions and device normalization
---------------------------------------------------------------

`validate-switch.ps1` covers Force + YADIF and BWDIF switching to GPU adaptive
and back while the graph runs, in both one-picture and one-field output modes.
The gate blocks before a key input packet without seeking, stopping or flushing
there. Every source picture/field time slot from zero through EOS must occur
exactly once, with continuous 40 ms or 20 ms timestamps and active GPU decoding.
Static controls and stable portions around each transition compare pixels to
standalone FFmpeg CUVID adaptive, or woven CUVID followed by YADIF/BWDIF. A fixed
one-second margin around each input gate excludes filter boundary padding from
pixel judgments; it does not relax timestamp, coverage or EOS requirements.

The same suite uses runtime-only settings to simulate a CUDA ordinal left after
a device disappeared. It requires an out-of-range ordinal to return Automatic,
map to selection row zero, decode on GPU 0 before Apply, and remain Automatic
after applying the normalized value. Explicit GPU 0 must remain valid. These
checks do not modify registry values, filter registration or system settings.
The row mapping assertion validates the property-page selection input; it does
not automate the visible property page. `-SkipDeviceProbe` is only for preserving
old transition failure evidence and always prevents an overall passed report.

```powershell
.\tests\cuvid-ffmpeg\validate-switch.ps1 -Package C:\path\to\candidate `
  -Platform x64 -HarnessPath C:\path\to\graph-regression-x64.exe `
  -OutputDirectory .\bin_build\cuvid-ffmpeg-20261011\fix4\switch-x64
```

## Pinned FFmpeg CUVID implementation

The CUVID changes are committed in the
[FFmpeg fork](https://github.com/JunliangRen/FFmpeg/tree/codex/cuvid-live-deinterlace)
at [`6a9dc3af66b77a709191a935d74d4d6c84e90d0b`](https://github.com/JunliangRen/FFmpeg/commit/6a9dc3af66b77a709191a935d74d4d6c84e90d0b),
based on `aaaf9481ca02e1394bf93a301df5b94ae1bb2cf5`. LAV's FFmpeg submodule
pins that commit, and both FFmpeg build scripts build it directly. A clean
recursive checkout therefore provides the CUVID implementation without applying
local source patches. Build provenance records the LAV commit and this FFmpeg
commit to identify the exact source used.

The pinned CUVID implementation fixes the output rate reported by FFmpeg's
CUVID decoder after another sequence callback for an existing decoder.
The callback restores the source cadence and applies the effective
deinterlacing multiplier before an existing decoder can return early.
When sequence timing is absent, the default path uses its separately stored,
undoubled caller rate or latest valid sequence rate. Repeated callbacks
therefore cannot multiply an already doubled output rate again.
Progressive sequences and frame-rate output retain the source cadence.
FIFO sizing retains its separate multiplier.

The decoder uses overflow-safe rational rescaling for the first second-field
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
