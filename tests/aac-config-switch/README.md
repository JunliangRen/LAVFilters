# AAC ADTS / PCE transition regression

This standalone DirectShow harness loads filters from a supplied package directory without registering them or changing player settings. It disables the graph clock, counts decoded PCM and video samples, and reuses the same graph across forward and backward seeks.

The external reproduction fixture is the 2025-03-04 Utacon broadcast TS used during development. Its sole AAC stream (PID 0x110, AAC LC, 48 kHz) changes from ADTS channel_configuration=0 with a PCE to channel_configuration=2 about 9.579 seconds into the recording. The fixture is not distributed with this repository. A different file needs matching segment boundaries and expectations.

Before the fix, the decoder retains m4ac.pce after the explicit ADTS configuration replaces the PCE. Decoding then fails with "channel element 1.2 is not allocated". Natural playback loses audio and forward seeks produce no PCM; backward seeks before the transition recover. The fix clears that stale flag only when a nonzero ADTS channel configuration is installed, retaining the separate LATM/PCE handling.

## Build and run

First build the Release filters and DirectShow base classes for the desired architecture. From the matching Visual Studio Native Tools command prompt at the repository root:

```bat
tests\aac-config-switch\build.cmd
bin_build\aac-config-switch\graph-regression-x64.exe "C:\path\to\x64-package" "F:\path\to\fixture.ts"
bin_build\aac-config-switch\graph-regression-x64.exe "C:\path\to\x64-package" "F:\path\to\fixture.ts" --av
bin_build\aac-config-switch\graph-regression-x64.exe "C:\path\to\x64-package" "F:\path\to\fixture.ts" --full
```

Use the x86 executable and package when built from the x86 tools prompt. The default run checks seven ranges: natural playback through the transition, repeated forward/backward seeks, a seek crossing the transition, and a forward seek to one minute. `--av` repeats those checks with software video decoding connected. `--full` decodes the complete audio stream. Each run returns zero only if all cases pass.

The checks require graph completion, nonzero PCM, expected PCM duration, and video output when connected. Tolerances account for missing initial PCE frames, the source's short gap at the transition, and bounded graphs ending at a video PTS. Full-file decoding is accelerated and does not establish real-time player or hardware-renderer behavior.

Initial validation on the supplied recording: x64 and x86 each passed 7 audio cases, 7 audio/video cases, and 1 complete-file audio case. The previous build failed 5 of the 7 audio cases on each architecture, while the two backward-seek controls passed.
