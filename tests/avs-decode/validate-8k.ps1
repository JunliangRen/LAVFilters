param(
    [Parameter(Mandatory=$true)][string]$Package,
    [ValidateSet('x64','x86','Win32')][string]$Platform='x64',
    [string]$HarnessPath,
    [string]$Fixture,
    [string]$ReferenceReport,
    [string]$ExistingGraphReport,
    [string]$OutputDirectory,
    [ValidateRange(1,2)][int[]]$Threads=@(1)
)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if($Platform -eq 'Win32') {$Platform='x86'}
if(-not $HarnessPath) {$HarnessPath=Join-Path $root "bin_build\avs-first\dualarch-validation\harness\$Platform\graph-regression-$Platform.exe"}
if(-not $Fixture) {$Fixture=Join-Path $root 'bin_build\avs-first\cctv8k-diagnosis\cctv8k-head.ts'}
if(-not $ReferenceReport) {$ReferenceReport=Join-Path $root 'bin_build\avs-first\dualarch-validation\8k-reference-threads1\reference.json'}
if(-not $OutputDirectory) {$OutputDirectory=Join-Path $root "bin_build\avs-first\dualarch-validation\$Platform\8k"}
$Package=(Resolve-Path -LiteralPath $Package).Path
$HarnessPath=(Resolve-Path -LiteralPath $HarnessPath).Path
$Fixture=(Resolve-Path -LiteralPath $Fixture).Path
$ReferenceReport=(Resolve-Path -LiteralPath $ReferenceReport).Path
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$summaryPath=Join-Path $OutputDirectory '8k-validation.json'
if(Test-Path -LiteralPath $summaryPath) {throw 'Choose a fresh OutputDirectory to preserve the existing 8K report'}
$reference=Get-Content -LiteralPath $ReferenceReport -Raw | ConvertFrom-Json
$refWhole=$reference.full_graph_report.segments | Where-Object name -EQ 'whole-file'
$inputHash=(Get-FileHash -LiteralPath $Fixture -Algorithm SHA256).Hash
if($inputHash -ne $reference.fixture_sha256) {throw '8K fixture SHA256 differs from the retained unchanged source prefix'}
if($ExistingGraphReport -and $Threads.Count -ne 1) {throw 'ExistingGraphReport requires exactly one thread setting'}
$expectedBits=if($Platform -eq 'x64') {64} else {32}
$testedUtc=[DateTime]::UtcNow.ToString('o')
$harnessHash=(Get-FileHash -LiteralPath $HarnessPath -Algorithm SHA256).Hash
$binaries=@{}
Get-ChildItem -LiteralPath $Package -File | Where-Object Extension -In '.dll','.ax' | ForEach-Object {$binaries[$_.Name]=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
$failures=[Collections.Generic.List[string]]::new()
function Verify([bool]$Condition,[string]$Message) {if(-not $Condition) {$failures.Add($Message); Write-Warning $Message}}
function Sequence($Segment) {return (@($Segment.frame_data | ForEach-Object sha256) -join ',')}
$records=@()
foreach($thread in $Threads) {
    $json=Join-Path $OutputDirectory "cctv8k-threads-$thread.json"
    $log=Join-Path $OutputDirectory "cctv8k-threads-$thread.log"
    if($ExistingGraphReport) {
        if($reference.source_graph_report_sha256 -and (Get-FileHash -LiteralPath $ExistingGraphReport -Algorithm SHA256).Hash -ne $reference.source_graph_report_sha256) {throw 'Saved graph SHA256 differs from the native-reference proof'}
        $saved=Get-Content -LiteralPath $ExistingGraphReport -Raw | ConvertFrom-Json
        if($saved.threads -ne $thread) {throw 'Existing graph thread setting differs from the requested reference'}
        Copy-Item -LiteralPath $ExistingGraphReport -Destination $json
        $exit=0
    } else {
        & $HarnessPath $Package $Fixture 10 $thread $json P010 600000 2>&1 | Out-File -LiteralPath $log -Encoding utf8
        $exit=$LASTEXITCODE
    }
    Verify ($exit -eq 0) "8K graph process failed, threads $thread, exit $exit"
    if(-not(Test-Path -LiteralPath $json)) {continue}
    try {$report=Get-Content -LiteralPath $json -Raw | ConvertFrom-Json} catch {$failures.Add("Invalid 8K graph report, threads $thread");continue}
    Verify ($report.pointer_bits -eq $expectedBits) "8K graph process architecture differs from $Platform"
    Verify ($report.segments.Count -eq 5) "8K graph missing seek/replay cases, threads $thread"
    $whole=$report.segments | Where-Object name -EQ 'whole-file'
    $replay=$report.segments | Where-Object name -EQ 'whole-replay'
    Verify ($whole.frames -eq $reference.current_whole_frames) "8K whole frame count differs, threads $thread"
    Verify ($whole.md5 -eq $refWhole.md5 -and (Sequence $whole) -eq (Sequence $refWhole)) "8K ordered pixels differ from retained preview2 validated graph, threads $thread"
    Verify ($whole.bytes -eq $refWhole.bytes -and $whole.precision_samples -eq $refWhole.precision_samples) "8K cumulative byte/precision counters differ, threads $thread"
    Verify ($whole.precision_samples -gt 0) "8K true 10-bit low precision samples absent, threads $thread"
    Verify ((Sequence $replay) -eq (Sequence $whole)) "8K replay changes decoded pixels, threads $thread"
    $coverage=@()
    foreach($segment in $report.segments) {
        Verify ($segment.pass -and $segment.event -eq 1 -and $segment.hr -eq 0) "8K completion failed, threads $thread, $($segment.name)"
        Verify ($segment.monotonic -and $segment.timestamps) "8K timestamps failed, threads $thread, $($segment.name)"
        foreach($frame in $segment.frame_data) {
            Verify ($frame.width -eq 7680 -and $frame.height -eq 4320) "8K dimensions changed, threads $thread, $($segment.name)"
            Verify ($frame.stop -gt $frame.start) "8K non-positive frame time, threads $thread, $($segment.name)"
        }
        if($segment.name -match 'seek|again') {
            $expected=@($whole.frame_data | Where-Object {$_.start -ge $segment.start -and $_.start -lt $segment.stop})
            $match=($segment.frames -eq $expected.Count -and (Sequence $segment) -eq (@($expected | ForEach-Object sha256) -join ','))
            Verify $match "8K complete seek coverage differs, threads $thread, $($segment.name): $($segment.frames)/$($expected.Count)"
            $coverage += [pscustomobject]@{name=$segment.name;expected_frames=$expected.Count;actual_frames=$segment.frames;passed=$match}
        }
    }
    $forward=$report.segments | Where-Object name -EQ 'forward-seek'
    $again=$report.segments | Where-Object name -EQ 'forward-again'
    Verify ((Sequence $forward) -eq (Sequence $again) -and (@($forward.frame_data | ForEach-Object start) -join ',') -eq (@($again.frame_data | ForEach-Object start) -join ',')) "8K repeated seek differs, threads $thread"
    $records += [pscustomobject]@{threads=$thread;whole_frames=$whole.frames;whole_md5=$whole.md5;bytes=$whole.bytes;precision_samples=$whole.precision_samples;seek_coverage=$coverage;report_file=[IO.Path]::GetFileName($json);report_sha256=(Get-FileHash -LiteralPath $json -Algorithm SHA256).Hash;report=$report}
    Write-Output "8K $Platform threads ${thread}: $($whole.frames) whole/replay frames, $($whole.bytes) canonical bytes, $($coverage.Count) complete seek ranges"
}
foreach($name in $binaries.Keys) {Verify ((Get-FileHash -LiteralPath (Join-Path $Package $name) -Algorithm SHA256).Hash -eq $binaries[$name]) "Candidate changed during 8K validation: $name"}
Verify ((Get-FileHash -LiteralPath $HarnessPath -Algorithm SHA256).Hash -eq $harnessHash) '8K graph harness changed during validation'
Verify ((Get-FileHash -LiteralPath $Fixture -Algorithm SHA256).Hash -eq $inputHash) '8K original short fixture changed during validation'
$summary=[pscustomobject]@{
    passed=($failures.Count -eq 0 -and $records.Count -eq $Threads.Count)
    architecture=$Platform
    pointer_bits=$expectedBits
    package=$Package
    tested_utc=$testedUtc
    completed_utc=[DateTime]::UtcNow.ToString('o')
    fixture=$Fixture
    fixture_bytes=(Get-Item -LiteralPath $Fixture).Length
    fixture_sha256=$inputHash
    fixture_modified=$false
    reference_report=$ReferenceReport
    reference_report_sha256=(Get-FileHash -LiteralPath $ReferenceReport -Algorithm SHA256).Hash
    pixel_reference=if($reference.pixel_reference) {$reference.pixel_reference} else {'Retained preview2 x64 DirectShow output, previously validated against native decoded frame count; no independent publisher pixel MD5 claim for this broadcast prefix'}
    existing_graph_report=$ExistingGraphReport
    reference_limits=$reference.limits
    incomplete_tail_thread_comparison=$reference.previous_threads8_comparison
    candidate_binary_sha256=$binaries
    harness=$HarnessPath
    harness_sha256=$harnessHash
    width=7680
    height=4320
    bits=10
    output_format='P010'
    frame_rate=50
    expected_whole_frames=$reference.current_whole_frames
    graph_runs=$records.Count
    segment_runs=@($records | ForEach-Object {$_.report.segments}).Count
    failures=@($failures)
    records=$records
    limits='Only the unchanged aligned first 64 MiB prefix of the supplied broadcast recording. Headless accelerated pixel capture with one or two decoder threads. This proves short-prefix decode/seek/EOS behavior and pixel regression parity; it does not prove sustained original-file playback, audio/video sync, hardware-renderer behavior, or 50 fps real-time performance.'
}
$text=$summary | ConvertTo-Json -Depth 15
[IO.File]::WriteAllText($summaryPath,($text -replace '\r?\n',"`r`n")+"`r`n",[Text.UTF8Encoding]::new($false))
if(-not $summary.passed) {throw "$($failures.Count) 8K validation failures; see $summaryPath"}
