# AVS software decoder graph validation

The harness loads LAV Splitter Source and LAV Video directly from a matching x64 or x86 package. It does not register filters or change player settings. Hardware decoding and deinterlacing use runtime-only disabled settings, and the graph clock is disabled.

Each graph decodes the whole fixture through natural EOS, seeks forward, seeks backward, repeats the forward seek, then replays the whole fixture with an unknown stop. Reports contain counts, timestamps, dimensions, flags, ordered frame SHA256 and whole-stream MD5. YV12 and NV12 are normalized to tightly packed yuv420p; padded P010 is normalized to yuv420p10le. The 10-bit test also counts nonzero low precision bits. Cumulative bytes and precision counters are uint64_t so the 8K test remains correct in a 32-bit process.

## Build and run

Build Release DirectShow base classes first (`bin_x64/lib/strmbase.lib` or `bin_Win32/lib/strmbase.lib`). The frame-PTS probe also needs the configured FFmpeg public headers, including `ffmpeg/libavutil/avconfig.h`.

From an x64 Visual Studio Native Tools prompt:

```bat
tests\avs-decode\build.cmd x64
```

From an x86 Visual Studio Native Tools prompt:

```bat
tests\avs-decode\build.cmd x86
```

`Win32` is an alias for x86. Omitting the platform uses the active Native Tools target. An optional second argument chooses a separate output directory. Defaults are `bin_build/avs-first/dualarch-validation/harness/{x64,x86}`. The build creates matching `graph-regression-{arch}.exe`, `frame-pts-probe-{arch}.exe`, and `smoke-load-{arch}.exe`. The x86 helpers are large-address-aware; this increases their address-space ceiling on 64-bit Windows, but does not remove 32-bit memory limits.

Run the corresponding package and executable, with a fresh output directory:

```powershell
tests\avs-decode\validate.ps1 -Platform x64 -Package F:\Repos\LAVFilters\bin_build\avs-first\packages\LAVFilters-AVS-preview3-20261007-x64-runtime -HarnessPath F:\Repos\LAVFilters\bin_build\avs-first\dualarch-validation\harness\x64\graph-regression-x64.exe -OutputDirectory F:\Repos\LAVFilters\bin_build\avs-first\dualarch-validation\x64\core-new

tests\avs-decode\validate.ps1 -Platform x86 -Package F:\Repos\LAVFilters\bin_build\avs-first\packages\LAVFilters-AVS-preview3-20261007-x86-runtime -HarnessPath F:\Repos\LAVFilters\bin_build\avs-first\dualarch-validation\harness\x86\graph-regression-x86.exe -OutputDirectory F:\Repos\LAVFilters\bin_build\avs-first\dualarch-validation\x86\core-new
```

`-HarnessPath` is optional when the default build directory is used. Existing completed reports are not overwritten. The default core suite uses automatic and one decoder thread, four official-source fixtures, and two synthetic stride fixtures with both YV12 and NV12 output: eight cases, sixteen graphs, eighty segments per architecture. It requires exact full counts, MD5 and ordered frame hashes; complete seek coverage matching whole-file frames whose starts are in each requested [start,stop) interval; repeated seek equality; monotonic timestamps and positive durations; EOS; whole replay; and identical pixels/times between thread settings. PE machine types and the actual graph process pointer width must match the requested architecture.

Reports bind the tested package DLL/AX hashes, harness hash, fixture manifest hash, and UTC times. Raw per-graph reports and logs remain beside `validation.json`. `smoke-load-{arch}.exe PACKAGE` additionally creates four native filter classes and loads IntelQuickSyncDecoder, without system registration. `summarize.ps1 -CoreReport ... -EightKReport ... -OutputPath ...` produces a compact report with a top-level candidate binary hash map and retains separate core, loadsmoke, and actual 8K scopes.

## Sources and timestamp preparation

The local manifest is `bin_build/avs-first/fixtures/manifest.json`. Source collections are pinned, downloaded originals and intermediate TS files are retained, and decoded references are build artifacts.

- AVS1 JiZhun: FFmpeg FATE, https://fate-suite.ffmpeg.org/cavs/cavs.mpg. The first three seconds are stream-copied to TS to avoid the short source's truncated tail. `fix-cavs-ts-pts.py` parses `picture_distance` like FFmpeg `cavsdec.c:decode_pic()` and requires a complete unique 0..75 sequence.
- AVS2 8-bit: https://github.com/pkuvcl/avs2stream at `96065ae3d3f940ebad5a0b84251b3cf27ecf201c`, `ES/BQSquare_416x240_60_ra/test.avs2`, copied to TS at 60 fps. The official reconstruction MD5 is `cf9babd3440b696c998179071a608b85`.
- AVS3 baseline 8-bit and 10-bit: https://github.com/uavs3/avs3stream at `e9fcc4eac77061213c8fb07c87a8a1106fb66fe8`, `TS/PartyScene_832x480_50_ra/test.ts` and `TS/MarketPlace_1920x1080_60_10bit_ra/test.ts`. Official reconstruction MD5 values are `d22455bea7f05a74e2f7e98a80ef09b6` and `ea46707dd7200b23c51878c03e48ff0f`. The 8-bit TS is unchanged. The original 10-bit TS has decode-order PTS despite reordered pictures, so the core test uses a documented timestamp derivative.

`fix-ts-pts.py` maps unique original PTS tokens to independently verified display order and changes only five PES PTS bytes per picture. The 10-bit mapping uses `frame-pts-probe-{arch}.exe PACKAGE INPUT OUTPUT.json` through the packaged FFmpeg API; official MD5 and standalone FFmpeg frame hashes separately verify display order. For AVS1, AVS2, and AVS3 10-bit, the final TS derivatives also use `remux-legal-dts.py`: FFmpeg setts assigns strictly increasing coding-order DTS early enough for every PTS, then the MPEG-TS muxer regenerates PES/PCR. Proofs check unchanged display PTS, packet bytes/order, cumulative ES SHA256, decoded pixel hashes/MD5, and lawful DTS/PCR. Originals and `*-pts-only.ts` intermediates are retained. This preparation does not promise repair of arbitrary damaged recordings.

The synthetic AVS2 cases encode testsrc2 at 432x240 and 418x240, 30 fps, 60 frames. Their 216-byte and 209-byte U/V rows exercise unaligned input chroma strides. Both YV12 and NV12 must match standalone davs2 and FFmpeg references. These are generated dimension regressions, not real broadcast samples.

```powershell
ffmpeg -f lavfi -i testsrc2=size=432x240:rate=30:duration=2 -c:v libxavs2 -pix_fmt yuv420p -g 32 -bf 7 -qp 32 -f avs2 avs2-align432.avs2
ffmpeg -fflags +genpts -r 30 -f avs2 -i avs2-align432.avs2 -c copy -f mpegts avs2-align432.ts
ffprobe -v error -select_streams v:0 -show_frames -show_entries frame=pts,best_effort_timestamp,pkt_dts,pict_type -of json avs2-align432.ts > avs2-align432-frames.json
python -B tests/avs-decode/fix-ts-pts.py avs2-align432.ts avs2-align432-frames.json avs2-align432-fixed.ts --fps 30
python -B tests/avs-decode/remux-legal-dts.py avs2-align432-fixed.ts avs2-align432-legal.ts --fps 30 --ffmpeg "D:\Program Files\DecodeSuite\ffmpeg.exe" --ffprobe "D:\Program Files\DecodeSuite\ffprobe.exe" --report avs2-align432-legal-dts-remux.json
ffmpeg -threads 1 -i avs2-align432-legal.ts -map 0:v:0 -an -fps_mode passthrough -pix_fmt yuv420p -f framehash -hash sha256 avs2-align432.framehash.txt
```

Use architecture-compatible standalone tools. Here DecodeSuite FFmpeg 8.0.1 prepares AVS1/AVS2; the 10-bit-capable `C:\Windows\ffmpeg.exe` prepares and references AVS3 10-bit. The 8-bit-only standalone ffprobe can still inspect the 10-bit stream's packet timestamps/hashes.

## Optional actual 8K short-prefix check

The supplied broadcast fixture is the existing unchanged aligned first 64 MiB (`cctv8k-head.ts`), 7680x4320 10-bit at 50 fps. Its hash is verified before and after testing. This prefix starts mid-recording and ends inside PES; native FFmpeg reports an end-of-cut PES mismatch. The tested thread1 output contains 213 frames. Its whole/replay MD5 and all frame SHA256 match a standalone FFmpeg thread1 reference. The prior thread8 output differs at only frame 209 near the cut; the old comparison report remains intact. That difference does not establish corruption of the full original recording or guarantee thread-independent recovery of an incomplete coded picture.

For this prefix, use the matching thread1 oracle, not the old thread8 output:

```powershell
tests\avs-decode\validate-8k.ps1 -Platform x86 -Package F:\Repos\LAVFilters\bin_build\avs-first\packages\LAVFilters-AVS-preview3-20261007-x86-runtime -HarnessPath F:\Repos\LAVFilters\bin_build\avs-first\dualarch-validation\harness-final\x86\graph-regression-x86.exe -ReferenceReport F:\Repos\LAVFilters\bin_build\avs-first\dualarch-validation\8k-reference-threads1\reference.json -OutputDirectory F:\Repos\LAVFilters\bin_build\avs-first\dualarch-validation\x86\8k-new -Threads 1
```

Use x64 and its matching paths for x64 testing. The graph helper accepts optional `[TIMEOUT_MS]` after its output format; the 8K wrapper uses 600000 per segment so low-thread decoding and pixel hashing have time to complete. Core checks retain the default 120000. `-ExistingGraphReport` can re-evaluate a saved, hash-bound graph against a newly completed standalone reference without modifying the original report or rerunning decoding.

Small-fixture x86 success is separate from actual 8K usability. One decoder thread is used for the actual prefix; the previous native measurements were about 884 MiB at one thread and near 4 GiB with automatic 20-thread decoding. Those older measurements are context, not a benchmark of the current candidate. Do not infer default-auto-thread 8K playback from low-resolution core results. The short-prefix tests do not establish 50 fps real-time performance, sustained full-recording playback, renderer behavior, or audio/video sync. AVS+, AVS2 10-bit, other AVS3 profiles, changing resolution, missing headers, arbitrary damaged-input recovery, hardware decoding, and other containers remain outside this suite.
