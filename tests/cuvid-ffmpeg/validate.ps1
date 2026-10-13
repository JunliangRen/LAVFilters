param(
    [Parameter(Mandatory=$true)][string]$Package,
    [ValidateSet('x64','x86')][string]$Platform = 'x64',
    [string]$FixtureDirectory,
    [string]$OutputDirectory,
    [string]$HarnessPath,
    [string]$AdaptiveReportPath,
    [string]$ArchitectureReferencePath,
    [switch]$SkipOldBackend,
    [string[]]$OnlyFixtures
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $FixtureDirectory) { $FixtureDirectory = Join-Path $root 'bin_build\cuvid-ffmpeg-20261010\fixtures' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root "bin_build\cuvid-ffmpeg-20261010\validation\$Platform" }
if (-not $HarnessPath) { $HarnessPath = Join-Path $root "bin_build\cuvid-ffmpeg-20261010\harness\$Platform\graph-regression-$Platform.exe" }
$Package = (Resolve-Path -LiteralPath $Package).Path
$FixtureDirectory = (Resolve-Path -LiteralPath $FixtureDirectory).Path
$HarnessPath = (Resolve-Path -LiteralPath $HarnessPath).Path
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
if (Test-Path -LiteralPath (Join-Path $OutputDirectory 'validation.json')) { throw 'Use a fresh OutputDirectory to preserve existing evidence.' }
function Pe-Machine([string]$Path) {
    $stream=[IO.File]::OpenRead($Path); $reader=[IO.BinaryReader]::new($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5a4d) { throw "Missing MZ header: $Path" }
        $stream.Position=0x3c; $offset=$reader.ReadInt32(); $stream.Position=$offset
        if ($reader.ReadUInt32() -ne 0x4550) { throw "Missing PE header: $Path" }
        return $reader.ReadUInt16()
    } finally { $reader.Dispose(); $stream.Dispose() }
}
$expectedMachine = if ($Platform -eq 'x64') { 0x8664 } else { 0x014c }
$expectedBits = if ($Platform -eq 'x64') { 64 } else { 32 }
$failures = [Collections.Generic.List[string]]::new()
function Verify([bool]$Condition, [string]$Message) { if (-not $Condition -and -not $failures.Contains($Message)) { $failures.Add($Message); Write-Warning $Message } }
function Frame-Sequence($Segment) { return (@($Segment.frame_data | ForEach-Object sha256) -join ',') }
function Sequence-Start($Whole, $Segment) {
    $source=@($Whole.frame_data); $target=@($Segment.frame_data)
    if (-not $target.Count -or $target.Count -gt $source.Count) { return -1 }
    for ($index=0;$index -le $source.Count-$target.Count;++$index) {
        if ($source[$index].sha256 -ne $target[0].sha256) { continue }
        $matches=$true
        for ($offset=1;$offset -lt $target.Count;++$offset) {
            if ($source[$index+$offset].sha256 -ne $target[$offset].sha256) { $matches=$false; break }
        }
        if ($matches) { return $index }
    }
    return -1
}
$started = [DateTime]::UtcNow.ToString('o')
$binaries = @(Get-ChildItem -LiteralPath $Package -File | Where-Object Extension -In '.dll','.ax' | Sort-Object Name | ForEach-Object {
    [pscustomobject]@{file=$_.Name;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash;bytes=$_.Length;machine=(Pe-Machine $_.FullName)}
})
foreach ($binary in $binaries) { Verify ($binary.machine -eq $expectedMachine) "Package architecture differs: $($binary.file)" }
Verify ((Pe-Machine $HarnessPath) -eq $expectedMachine) 'Harness architecture differs'
$harnessHash = (Get-FileHash -LiteralPath $HarnessPath).Hash
$manifestPath = Join-Path $FixtureDirectory 'manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$manifestHash = (Get-FileHash -LiteralPath $manifestPath).Hash
$architectureReferences=$null
$architectureReferenceHash=$null
if ($ArchitectureReferencePath) {
    $ArchitectureReferencePath=(Resolve-Path -LiteralPath $ArchitectureReferencePath).Path
    $architectureReferenceHash=(Get-FileHash -LiteralPath $ArchitectureReferencePath).Hash
    $architectureReferences=Get-Content -LiteralPath $ArchitectureReferencePath -Raw | ConvertFrom-Json
    Verify ($architectureReferences.passed -and $architectureReferences.platform -eq $Platform) 'CPU reference did not pass for this architecture'
    Verify ($architectureReferences.fixture_manifest_sha256 -eq $manifestHash) 'CPU reference used a different fixture manifest'
    Verify ($architectureReferences.reference_tool.machine -eq $expectedMachine -and (Pe-Machine $architectureReferences.reference_tool.path) -eq $expectedMachine) 'CPU reference tool architecture differs'
    Verify ((Get-FileHash -LiteralPath $architectureReferences.reference_tool.path).Hash -eq $architectureReferences.reference_tool.sha256) 'CPU reference tool hash differs'
    foreach ($binary in $binaries) {
        $referenceBinary=@($architectureReferences.candidate_binary_sha256 | Where-Object file -EQ $binary.file)
        Verify ($referenceBinary.Count -eq 1 -and $referenceBinary[0].sha256 -eq $binary.sha256) "CPU reference used a different candidate binary: $($binary.file)"
    }
    $seenFixtures=@{}
    foreach ($reference in $architectureReferences.records) {
        $referenceFixture=@($manifest.fixtures | Where-Object name -EQ $reference.fixture)
        Verify ($referenceFixture.Count -eq 1 -and $referenceFixture[0].sha256 -eq $reference.source_sha256) "CPU reference source differs: $($reference.fixture)"
        Verify (-not $seenFixtures.ContainsKey($reference.fixture)) "Duplicate CPU reference: $($reference.fixture)"
        $seenFixtures[$reference.fixture]=$true
        # Architecture-specific IDCT differences affect these 8-bit software
        # codecs only. GPU and high-bit references always remain standalone.
        Verify ($reference.fixture -in 'mpeg4-bframes','mpeg4-avi-fallback','mpeg2-tff','mpeg2-bff' -and $referenceFixture[0].bits -eq 8 -and $referenceFixture[0].canonical_format -eq 'yuv420p' -and $reference.pixel_format -eq 'yuv420p' -and $reference.thread_count -eq 1 -and $reference.idct_algo -eq 0 -and $reference.decoder -eq $(if($reference.fixture -like 'mpeg4-*'){'mpeg4'}else{'mpeg2video'})) "CPU reference decoder settings differ: $($reference.fixture)"
        Verify ((Get-FileHash -LiteralPath $reference.framehash).Hash -eq $reference.framehash_sha256) "CPU reference frame hash file differs: $($reference.fixture)"
    }
}
$adaptiveReport=$null
if ($AdaptiveReportPath) {
    $AdaptiveReportPath=(Resolve-Path -LiteralPath $AdaptiveReportPath).Path
    $adaptiveReport=Get-Content -LiteralPath $AdaptiveReportPath -Raw | ConvertFrom-Json
    Verify ($adaptiveReport.passed -and $adaptiveReport.platform -eq $Platform) 'Adaptive packet-history oracle did not pass for this architecture'
    Verify ($adaptiveReport.harness_sha256 -eq $harnessHash) 'Adaptive oracle used a different harness'
    Verify ($adaptiveReport.fixture_manifest_sha256 -eq $manifestHash) 'Adaptive oracle used a different fixture manifest'
    foreach ($binary in $binaries) {
        $referenceBinary=$adaptiveReport.candidate_binary_sha256 | Where-Object file -EQ $binary.file
        Verify ($referenceBinary -and $referenceBinary.sha256 -eq $binary.sha256) "Adaptive oracle used a different candidate binary: $($binary.file)"
    }
}
$cases = @()
foreach ($fixture in $manifest.fixtures) {
    if ($OnlyFixtures -and $fixture.name -notin $OnlyFixtures) { continue }
    $cases += @{fixture=$fixture;backend=0;mode='disable';expected='software';reference='software';device=-1;id="$($fixture.name)-software"}
    $expected = if ($fixture.fallback) { 'software' } else { 'cuvid (ffmpeg)' }
    $mode = if ($fixture.interlaced) { 'weave' } else { 'disable' }
    $reference = if ($fixture.fallback -or -not $manifest.hardware_references) { 'software' } else { 'weave' }
    $cases += @{fixture=$fixture;backend=6;mode=$mode;expected=$expected;reference=$reference;device=-1;id="$($fixture.name)-cuvid-ffmpeg"}
    if ($fixture.interlaced) {
        foreach ($deint in 'adaptive-single','adaptive-double') {
            $cases += @{fixture=$fixture;backend=6;mode=$deint;expected='cuvid (ffmpeg)';reference=$deint;device=-1;id="$($fixture.name)-$deint"}
        }
    }
    if ($fixture.name -eq 'h264-bframes') {
        foreach ($index in 0,999) {
            $cases += @{fixture=$fixture;backend=6;mode='disable';expected='cuvid (ffmpeg)';reference=$reference;device=$index;id="h264-bframes-device-$index"}
        }
        $cases += @{fixture=$fixture;backend=6;mode='disable';expected='cuvid (ffmpeg)';reference=$reference;device=-1;format='YV12';id='h264-bframes-yv12'}
        $cases += @{fixture=$fixture;backend=6;mode='aggressive-weave';expected='cuvid (ffmpeg)';reference=$reference;device=-1;id='h264-bframes-aggressive-weave'}
        foreach ($override in 'adaptive-force','adaptive-tff','adaptive-bff') {
            $cases += @{fixture=$fixture;backend=0;mode=$override;expected='software';reference='software';device=-1;id="h264-bframes-$override-software"}
            if ($override -eq 'adaptive-force') {
                $cases += @{fixture=$fixture;backend=6;mode=$override;expected='cuvid (ffmpeg)';reference='bounded-force';device=-1;id="h264-bframes-$override-cuvid-ffmpeg"}
            } else {
                $cases += @{fixture=$fixture;backend=1;mode=$override;expected='cuvid';reference='self';device=-1;id="h264-bframes-$override-legacy-control"}
                $cases += @{fixture=$fixture;backend=6;mode=$override;expected='cuvid (ffmpeg)';reference='legacy-control';device=-1;id="h264-bframes-$override-cuvid-ffmpeg"}
            }
        }
        if (-not $SkipOldBackend) {
            $cases += @{fixture=$fixture;backend=1;mode='disable';expected='cuvid';reference=$reference;device=-1;id='h264-bframes-old-cuvid'}
        }
    }
}
$records = @()
Verify ($cases.Count -gt 0) 'No matching fixture cases selected'
foreach ($case in $cases) {
    $fixture = $case.fixture
    $id = $case.id
    $inputFile = Join-Path $FixtureDirectory $fixture.file
    Verify ((Get-FileHash -LiteralPath $inputFile).Hash -eq $fixture.sha256) "Fixture changed: $id"
    $outputFormat = if ($case.format) { $case.format } else { $fixture.output_format }
    $jsonPath = Join-Path $OutputDirectory "$id.json"
    $logPath = Join-Path $OutputDirectory "$id.log"
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $HarnessPath $Package $inputFile $fixture.bits 1 $jsonPath $outputFormat $case.backend $case.mode $case.expected $case.device 120000 2>&1 | Out-File -LiteralPath $logPath -Encoding utf8; $code=$LASTEXITCODE }
    finally { $ErrorActionPreference = $previousPreference }
    Verify ($code -eq 0) "Graph failed: $id ($code)"
    if (-not (Test-Path -LiteralPath $jsonPath)) { continue }
    try { $report = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json } catch { $failures.Add("Invalid report: $id"); continue }
    Verify ($report.pointer_bits -eq $expectedBits) "Process architecture differs: $id"
    Verify ($report.backend -eq $case.backend) "Requested backend differs: $id"
    Verify ($report.segments.Count -eq 5) "Missing decode/seek segments: $id"
    $whole = $report.segments | Where-Object name -EQ 'whole-file'
    $replay = $report.segments | Where-Object name -EQ 'whole-replay'
    $reference = $fixture.references.($case.reference)
    $legacyReference=$null
    if ($case.reference -eq 'legacy-control') {
        $legacyReference=$records | Where-Object id -EQ "$($fixture.name)-$($case.mode)-legacy-control"
        $referenceWhole=$legacyReference.report.segments | Where-Object name -EQ 'whole-file'
        Verify ([bool]$referenceWhole) "Missing independent legacy CUVID control: $id"
        if ($referenceWhole) {
            $reference=@{frames=$referenceWhole.frames;md5=$referenceWhole.md5}
            $referenceHashes=@($referenceWhole.frame_data | ForEach-Object sha256)
        }
    }
    $architectureReference=$null
    if ($case.reference -eq 'software' -and $case.expected -eq 'software' -and $architectureReferences) {
        $architectureReference=$architectureReferences.records | Where-Object fixture -EQ $fixture.name
        if ($architectureReference) { $reference=$architectureReference }
    }
    if ($reference) {
        if (-not $legacyReference) {
            $framehashPath=if($architectureReference){$reference.framehash}else{Join-Path $FixtureDirectory $reference.framehash}
            $referenceHashes = @(Get-Content -LiteralPath $framehashPath | Where-Object { $_ -match '^0,' } | ForEach-Object { ($_ -split ',')[-1].Trim() })
        }
        Verify ($whole.frames -eq $reference.frames) "Reference frame count differs: $id ($($whole.frames) versus $($reference.frames))"
        Verify ($whole.md5 -eq $reference.md5) "Reference full pixel MD5 differs: $id"
        Verify ((Frame-Sequence $whole) -eq ($referenceHashes -join ',')) "Reference ordered frame hashes differ: $id"
    } elseif ($case.reference -eq 'bounded-force') {
        # Force processes progressive pixels that the standalone CUVID binary
        # and legacy decoder cannot independently reproduce. Assert complete
        # source coverage here, with replay/repeated-seek equality below.
        Verify ($whole.frames -eq $fixture.references.software.frames) "Forced progressive source coverage differs: $id"
    } elseif ($case.reference -ne 'self') { $failures.Add("Missing reference mode: $id/$($case.reference)") }
    Verify ($whole.frame_data[0].start -eq 0) "Timeline does not begin at zero: $id"
    Verify ((Frame-Sequence $replay) -eq (Frame-Sequence $whole)) "Whole replay changes ordered pixels: $id"
    Verify ($replay.md5 -eq $whole.md5) "Whole replay changes MD5: $id"
    if ($fixture.bits -gt 8) { Verify ($whole.precision_samples -gt 0) "Low high-bit precision bits absent: $id" }
    $expectedDuration = [long](10000000 / $fixture.fps / $(if ($case.mode -eq 'adaptive-double') { 2 } else { 1 }))
    $coverage = @()
    foreach ($segment in $report.segments) {
        Verify ($segment.pass -and $segment.hr -eq 0 -and $segment.event -eq 1) "EOS/status failure: $id/$($segment.name)"
        Verify ($segment.monotonic -and $segment.timestamps) "Timestamp failure: $id/$($segment.name)"
        Verify ($segment.decoder_matches) "Actual decoder differs from expected: $id/$($segment.name)/$($segment.decoder)"
        if ($case.expected -ne 'software') {
            Verify ([bool]$segment.active_device) "Active hardware device missing: $id/$($segment.name)"
            Verify ($segment.support_after -eq 2) "Backend not reported running: $id/$($segment.name)"
            Verify ($segment.active_device -eq $report.active_device) "GPU changed across seek: $id/$($segment.name)"
        }
        foreach ($frame in $segment.frame_data) {
            Verify ($frame.width -eq $fixture.width -and $frame.height -eq $fixture.height) "Dimensions differ: $id/$($segment.name)"
            Verify ($frame.stop -gt $frame.start) "Nonpositive frame duration: $id/$($segment.name)"
            Verify ($frame.avg_duration -eq $expectedDuration) "Output media AvgTimePerFrame differs: $id/$($segment.name) ($($frame.avg_duration) versus $expectedDuration)"
            if ($segment.name -in 'whole-file','whole-replay') {
                Verify (($frame.stop - $frame.start) -eq $expectedDuration) "Sample duration differs: $id/$($segment.name) ($($frame.stop - $frame.start) versus $expectedDuration)"
            }
            if ($case.mode -in 'adaptive-single','adaptive-double','aggressive-weave','adaptive-force','adaptive-tff','adaptive-bff' -and $case.expected -ne 'software' -and $case.reference -ne 'self') {
                Verify (($frame.flags -band 8) -eq 8) "Progressive output lacks weave flag: $id/$($segment.name)"
                Verify ($frame.media_interlace_flags -eq 0) "Progressive output media is flagged interlaced: $id/$($segment.name)"
            }
        }
        if ($segment.name -match 'seek|again') {
            if ($case.reference -eq 'bounded-force') {
                $baseline=$records | Where-Object id -EQ "$($fixture.name)-software"
                $controlSegment=$baseline.report.segments | Where-Object name -EQ $segment.name
                $matches=$controlSegment -and $segment.frames -eq $controlSegment.frames -and (@($segment.frame_data | ForEach-Object start)-join ',') -eq (@($controlSegment.frame_data | ForEach-Object start)-join ',')
                Verify ([bool]$matches) "Forced progressive seek loses source display positions: $id/$($segment.name)"
                $coverage += @{segment=$segment.name;actual_frames=$segment.frames;source_frames=$controlSegment.frames;independent_forced_pixels=$false;pass=[bool]$matches}
            } elseif ($case.reference -eq 'self') {
                # This legacy graph supplies the independent GPU control for
                # the following FFmpeg case. Adaptive seek history can differ
                # from whole playback, so its own whole-file pixels are not a
                # valid seek oracle.
                $coverage += @{segment=$segment.name;actual_frames=$segment.frames;independent_legacy_gpu_control=$true;pass=$segment.pass}
            } elseif ($legacyReference) {
                $controlSegment=$legacyReference.report.segments | Where-Object name -EQ $segment.name
                $matches=$controlSegment -and (Frame-Sequence $segment) -eq (Frame-Sequence $controlSegment) -and (@($segment.frame_data | ForEach-Object start)-join ',') -eq (@($controlSegment.frame_data | ForEach-Object start)-join ',')
                Verify ([bool]$matches) "Override seek differs from independent legacy CUVID: $id/$($segment.name)"
                $coverage += @{segment=$segment.name;actual_frames=$segment.frames;oracle_frames=$controlSegment.frames;legacy_gpu_oracle=$true;pass=[bool]$matches}
            } elseif ($case.mode -in 'adaptive-single','adaptive-double') {
                $oracleCase=$adaptiveReport.records | Where-Object id -EQ $id
                $oracleSegment=$oracleCase.segments | Where-Object name -EQ $segment.name
                $matches=$oracleSegment -and $oracleSegment.passed -and $oracleCase.source_sha256 -eq $fixture.sha256 -and $segment.frames -eq $oracleSegment.reference_frames -and (Frame-Sequence $segment) -eq ($oracleSegment.aligned_hashes -join ',')
                Verify ([bool]$matches) "Exact-packet GPU seek oracle differs or is absent: $id/$($segment.name)"
                $coverage += @{segment=$segment.name;actual_frames=$segment.frames;oracle_frames=$oracleSegment.reference_frames;packet_history_oracle=$true;pass=[bool]$matches}
            } else {
                $sequenceStart=Sequence-Start $whole $segment
                Verify ($sequenceStart -ge 0) "Seek output is not a contiguous whole-file pixel sequence: $id/$($segment.name)"
                if ($sequenceStart -ge 0) {
                    for ($offset=0;$offset -lt $segment.frames;++$offset) {
                        Verify (($whole.frame_data[$sequenceStart+$offset].start-$segment.start) -eq $segment.frame_data[$offset].start) "Seek timestamps differ from whole-file display positions: $id/$($segment.name)"
                    }
                    Verify ($whole.frame_data[$sequenceStart].start -ge $segment.start -and $whole.frame_data[$sequenceStart].start -le $segment.start+$expectedDuration) "Seek begins outside requested start frame: $id/$($segment.name)"
                }
                $coverage += @{segment=$segment.name;whole_sequence_start=$sequenceStart;actual_frames=$segment.frames;pass=($sequenceStart -ge 0)}
            }
        }
    }
    $forward = $report.segments | Where-Object name -EQ 'forward-seek'
    $again = $report.segments | Where-Object name -EQ 'forward-again'
    Verify ((Frame-Sequence $forward) -eq (Frame-Sequence $again)) "Repeated forward seek changes pixels: $id"
    Verify ((@($forward.frame_data | ForEach-Object start) -join ',') -eq (@($again.frame_data | ForEach-Object start) -join ',')) "Repeated forward seek changes timestamps: $id"
    $records += [pscustomobject]@{id=$id;fixture=$fixture.name;source_sha256=$fixture.sha256;reference_mode=$case.reference;architecture_cpu_reference=[bool]$architectureReference;backend=$case.backend;mode=$case.mode;expected_decoder=$case.expected;report=$report;seek_coverage=$coverage;log=[IO.Path]::GetFileName($logPath)}
    Write-Output "$id`: decoder=$($whole.decoder), frames=$($whole.frames), md5=$($whole.md5)"
}
foreach ($record in $records | Where-Object { $_.backend -ne 0 -and $_.mode -notin 'adaptive-single','adaptive-double','adaptive-force','adaptive-tff','adaptive-bff' }) {
    $baseline=$records | Where-Object id -EQ "$($record.fixture)-software"
    if (-not $baseline) { continue }
    $whole=$record.report.segments | Where-Object name -EQ 'whole-file'
    $baselineWhole=$baseline.report.segments | Where-Object name -EQ 'whole-file'
    foreach ($segment in $record.report.segments | Where-Object name -Match 'seek|again') {
        $control=$baseline.report.segments | Where-Object name -EQ $segment.name
        Verify ($segment.frames -eq $control.frames) "Seek frame coverage differs from software splitter control: $($record.id)/$($segment.name)"
        Verify ((Sequence-Start $whole $segment) -eq (Sequence-Start $baselineWhole $control)) "Seek display positions differ from software splitter control: $($record.id)/$($segment.name)"
        Verify ((@($segment.frame_data | ForEach-Object start) -join ',') -eq (@($control.frame_data | ForEach-Object start) -join ',')) "Seek timestamps differ from software splitter control: $($record.id)/$($segment.name)"
    }
}
foreach ($binary in $binaries) { Verify ((Get-FileHash -LiteralPath (Join-Path $Package $binary.file)).Hash -eq $binary.sha256) "Candidate changed: $($binary.file)" }
Verify ((Get-FileHash -LiteralPath $HarnessPath).Hash -eq $harnessHash) 'Harness changed during testing'
Verify ((Get-FileHash -LiteralPath $manifestPath).Hash -eq $manifestHash) 'Fixture manifest changed during testing'
if ($architectureReferences) {
    Verify ((Get-FileHash -LiteralPath $ArchitectureReferencePath).Hash -eq $architectureReferenceHash) 'CPU reference manifest changed during testing'
    Verify ((Get-FileHash -LiteralPath $architectureReferences.reference_tool.path).Hash -eq $architectureReferences.reference_tool.sha256) 'CPU reference tool changed during testing'
    foreach ($reference in $architectureReferences.records) {
        Verify ((Get-FileHash -LiteralPath $reference.framehash).Hash -eq $reference.framehash_sha256) "CPU reference changed during testing: $($reference.fixture)"
    }
}
$summary = [pscustomobject]@{
    scope='Native headless DirectShow graph, locally loaded filters, runtime settings; synthetic codec/profile and GPU deinterlace fixtures plus existing AVS3 software fallback; no renderer/audio/long-run claim'
    platform=$Platform;package=$Package;harness=$HarnessPath;started_utc=$started;completed_utc=[DateTime]::UtcNow.ToString('o');candidate_binary_sha256=$binaries;harness_sha256=$harnessHash;fixture_manifest_sha256=$manifestHash
    requested_graphs=$cases.Count;graph_runs=$records.Count;segment_runs=@($records | ForEach-Object {$_.report.segments}).Count;passed=($failures.Count -eq 0 -and $records.Count -eq $cases.Count);failures=@($failures);records=$records
    adaptive_report=$AdaptiveReportPath;adaptive_report_sha256=if($AdaptiveReportPath){(Get-FileHash -LiteralPath $AdaptiveReportPath).Hash}else{$null}
    architecture_reference=$ArchitectureReferencePath;architecture_reference_sha256=$architectureReferenceHash
}
$json=$summary | ConvertTo-Json -Depth 18
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'validation.json'), ($json -replace '\r?\n', "`r`n") + "`r`n", [Text.UTF8Encoding]::new($false))
if (-not $summary.passed) { throw "$($failures.Count) validation failures; see validation.json" }
Write-Output "$($summary.graph_runs) graphs / $($summary.segment_runs) complete decode and seek segments passed."
