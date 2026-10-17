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

Small-fixture x86 success is separate from actual 8K usability. One decoder thread is used for the actual prefix; the previous native measurements were about 884 MiB at one thread and near 4 GiB with automatic 20-thread decoding. Those older measurements are context, not a benchmark of the current candidate. Do not infer default-auto-thread 8K playback from low-resolution core results. The short-prefix tests do not establish 50 fps real-time performance, sustained full-recording playback, renderer behavior, or audio/video sync. AVS+, other AVS3 profiles, missing headers, arbitrary damaged-input recovery, hardware decoding, and other containers remain outside this suite. AVS2 10-bit uses the separate targeted check below.

## AVS2 10-bit targeted broadcast and instance checks

`build.cmd` also builds `codec-instances-{arch}.exe`. This helper loads the candidate FFmpeg DLLs and explicitly opens `libdavs2`; it never registers filters or changes settings. Inputs must be bounded AVS2 fixtures: each is limited to 128 MiB of video packet data and 8192 packets. The supplied prefix ending at a complete GOP and PES boundary in the Guangdong TV recording and the existing official AVS2 8-bit fixture are suitable inputs. Keep the original recording read-only; do not pass the entire recording to the full-fixture graph helper.

```powershell
tests\avs-decode\validate-avs2-10bit.ps1 -Platform x64 -Package F:\Repos\LAVFilters\bin_build\avs2-10bit-20261018\x64\candidate -Fixture F:\Repos\LAVFilters\bin_build\avs2-10bit-20261018\fixtures\tail-boundary\gdtv-before-seq-350.ts -ReferenceReport F:\Repos\LAVFilters\bin_build\avs2-10bit-20261018\fixtures\tail-boundary\reference-before-350.json -HarnessDirectory F:\Repos\LAVFilters\bin_build\avs2-10bit-20261018\tests\x64 -OutputDirectory F:\Repos\LAVFilters\bin_build\avs2-10bit-20261018\x64\avs2-10bit-new
```

The final unchanged TS prefix ends immediately before the next sequence header:
350 video PES packets, 32,039,336 bytes, SHA256
`365182ec54f6219b0fb5389bb1e0d04fe71ad8243e442a14df86836bc45f6774`.
Its separate scalar decoder reference contains 350 frames, MD5
`ee75d71a8b347992fb4afa73a8d491ca`. That decoder uses the same source family;
this is an independent build and scalar path, not an independent codec algorithm.
Arbitrary PES cuts can leave incomplete pictures; retain the extraction boundary
and reference provenance rather than accepting a candidate-generated oracle.

Use x86 and its matching candidate and helpers for x86. `-Threads` defaults to one and two decoder threads. `-InstancesThreads` defaults to two; neither setting claims default-auto-thread memory or performance. Use a fresh output directory. The independent reference JSON must contain `fixture_sha256`, `bits` (10), `width`, `height`, `frames`, canonical planar `md5`, ordered `frame_sha256`, `reference` provenance, and `limits`. An optional `frame_rate` also checks sample durations. Generate the pixel oracle through a separate standalone decoder build, retaining its revision, executable/source hashes, input ES/prefix hashes, and output format. Do not derive a new oracle from the candidate under test.

Complete-prefix whole and replay decoding is clean. Artificial forward-seek stop
boundaries can produce decoder errors during preroll beyond the delivered
segment. The checks still require every delivered frame and timestamp to match
the whole capture; passing them does not establish arbitrary-cut recovery.

The existing graph helper checks P010 output against that independent yuv420p10le reference, retains nonzero luma low-bit counts, and exercises whole-fixture EOS, forward/backward/repeated seek, and replay. The unchanged broadcast TS can start after zero because its audio/video offsets are preserved; this check compares seek output to the whole capture's absolute times rather than requiring a rewritten zero-based timeline.

The direct API helper runs sixteen cases: independent 8-bit and 10-bit baselines; two simultaneously live contexts with interleaved packets; two contexts decoding in parallel host threads; the same context switched 8-to-10-to-8 and 10-to-8-to-10 with flush between each input; both sequences again without flush so old delayed frames must be drained before switching; and partial input discarded by flush followed by full replay for each depth. It compares dimensions, bit depth, PTS, duration, ordered canonical SHA256, cumulative bytes, and luma precision counts to the baselines. The wrapper also compares 10-bit baseline pixels to the independent oracle and 8-bit baseline pixels to the existing unchanged official oracle. The no-flush sequence tests intentionally concatenate fixture timelines; they test decoder state and do not imply a continuous broadcast timestamp sequence.

The wrapper also launches `codec-instances-{arch}.exe --cold-8 PACKAGE AVS2_8.ts OUTPUT.json THREADS` and the corresponding `--cold-10` mode in separate fresh processes. Each demuxes packets without `avformat_find_stream_info`, since stream probing can decode and warm the library before the test. Two contexts synchronize immediately before their first packet, then decode concurrently using the same depth. A third decode afterwards supplies a warm baseline. All six outputs must match the applicable independent pixel oracle. This checks the deferred backend initialization path, including its shared primitive-table initialization, without relying on a warmed mixed-depth test.

`avs2-10bit-validation.json` binds fixture, candidate, helper, and reference hashes. Logs and raw graph/API reports are retained. Run the separate unchanged core `validate.ps1` suite as well to cover AVS1, AVS2 8-bit, AVS3 8/10-bit, and stride fixtures. Short-prefix success establishes the tested software decode and seek behavior; it does not establish full-recording playback, rendering, audio/video synchronization, default-thread resource use, or real-time 4K50 decoding.
