param(
    [Parameter(Mandatory = $true)][string]$Package,
    [string]$FixtureDirectory,
    [string]$OutputDirectory,
    [int[]]$Threads = @(0,1),
    [ValidateSet('x64','x86','Win32')][string]$Platform = 'x64',
    [string]$HarnessPath
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $FixtureDirectory) { $FixtureDirectory = Join-Path $root 'bin_build\avs-first\fixtures' }
if ($Platform -eq 'Win32') { $Platform = 'x86' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root "bin_build\avs-first\dualarch-validation\$Platform\core" }
$Package = (Resolve-Path -LiteralPath $Package).Path
$FixtureDirectory = (Resolve-Path -LiteralPath $FixtureDirectory).Path
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
if (Test-Path -LiteralPath (Join-Path $OutputDirectory 'validation.json')) { throw 'Choose a fresh OutputDirectory to preserve the existing validation report' }
if (-not $HarnessPath) { $HarnessPath = Join-Path $root "bin_build\avs-first\dualarch-validation\harness\$Platform\graph-regression-$Platform.exe" }
$capture = (Resolve-Path -LiteralPath $HarnessPath).Path
$expectedPointerBits = if ($Platform -eq 'x64') { 64 } else { 32 }
$expectedMachine = if ($Platform -eq 'x64') { 0x8664 } else { 0x014c }
function Get-PeMachine([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5a4d) { throw "Missing MZ header: $Path" }
        $stream.Position = 0x3c
        $offset = $reader.ReadInt32()
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550) { throw "Missing PE header: $Path" }
        return $reader.ReadUInt16()
    } finally { $reader.Dispose(); $stream.Dispose() }
}
$testedUtc = [DateTime]::UtcNow.ToString('o')
$candidateBinaries = @(Get-ChildItem -LiteralPath $Package -Recurse -File | Where-Object Extension -In '.dll','.ax' | Sort-Object FullName | ForEach-Object {
    [pscustomobject]@{ file=$_.FullName.Substring($Package.Length + 1); sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash; bytes=$_.Length; pe_machine=(Get-PeMachine $_.FullName) }
})
$harnessSha256 = (Get-FileHash -LiteralPath $capture -Algorithm SHA256).Hash
$manifest = Get-Content -LiteralPath (Join-Path $FixtureDirectory 'manifest.json') -Raw | ConvertFrom-Json
$records = @()
$failures = [Collections.Generic.List[string]]::new()
function Verify([bool]$Condition, [string]$Message) {
    if (-not $Condition) { $failures.Add($Message); Write-Warning $Message }
}
Verify ((Get-PeMachine $capture) -eq $expectedMachine) "Harness PE architecture differs from $Platform"
foreach ($binary in $candidateBinaries) { Verify ($binary.pe_machine -eq $expectedMachine) "Candidate PE architecture differs from ${Platform}: $($binary.file)" }
function Frame-Sequence($Segment) { return (@($Segment.frame_data | ForEach-Object sha256) -join ',') }
foreach ($fixture in $manifest.fixtures) {
    $inputFile = Join-Path $FixtureDirectory $fixture.file
    if ((Get-FileHash -LiteralPath $inputFile -Algorithm SHA256).Hash -ne $fixture.sha256) { throw "Fixture SHA256 differs: $($fixture.name)" }
    $referencePath = Join-Path $FixtureDirectory $fixture.reference_framehash
    $referenceHashes = @(Get-Content -LiteralPath $referencePath | Where-Object { $_ -match '^0,' } | ForEach-Object { ($_ -split ',')[-1].Trim() })
    if ($referenceHashes.Count -ne $fixture.frames) { throw "Incomplete reference hashes: $($fixture.name)" }
    foreach ($thread in $Threads) {
        $jsonPath = Join-Path $OutputDirectory "$($fixture.name)-threads-$thread.json"
        $logPath = Join-Path $OutputDirectory "$($fixture.name)-threads-$thread.log"
        $outputFormat = if ($fixture.output_format) { $fixture.output_format } elseif ($fixture.bits -eq 10) { 'P010' } else { 'YV12' }
        & $capture $Package $inputFile $fixture.bits $thread $jsonPath $outputFormat 2>&1 | Out-File -LiteralPath $logPath -Encoding utf8
        $exitCode = $LASTEXITCODE
        Verify ($exitCode -eq 0) "Graph failed: $($fixture.name), threads $thread, exit $exitCode"
        if (-not (Test-Path -LiteralPath $jsonPath)) { continue }
        try { $report = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json } catch { $failures.Add("Invalid graph report: $($fixture.name), threads $thread"); continue }
        Verify ($report.pointer_bits -eq $expectedPointerBits) "Graph process architecture differs from ${Platform}: $($fixture.name), threads $thread"
        Verify ($report.segments.Count -eq 5) "Missing seek cases: $($fixture.name), threads $thread"
        $whole = $report.segments | Where-Object name -EQ 'whole-file'
        $replay = $report.segments | Where-Object name -EQ 'whole-replay'
        Verify ($whole.frames -eq $fixture.frames) "Full frame count differs: $($fixture.name), threads $thread, actual $($whole.frames), reference $($fixture.frames)"
        Verify ($whole.md5 -eq $fixture.reference_md5) "Full YUV MD5 differs: $($fixture.name), threads $thread"
        Verify ((Frame-Sequence $whole) -eq ($referenceHashes -join ',')) "Per-frame SHA256 differs: $($fixture.name), threads $thread"
        Verify ((Frame-Sequence $replay) -eq (Frame-Sequence $whole)) "Full replay changes frames: $($fixture.name), threads $thread"
        Verify ($replay.md5 -eq $whole.md5) "Full replay changes pixels: $($fixture.name), threads $thread"
        if ($fixture.bits -eq 10) { Verify ($whole.precision_samples -gt 0) "10-bit low precision bits absent: $($fixture.name), threads $thread" }
        Verify ($whole.frame_data[0].start -eq 0) "Whole-file timeline does not begin at zero: $($fixture.name), threads $thread, first $($whole.frame_data[0].start)"
        $seekCoverage = @()
        foreach ($segment in $report.segments) {
            Verify ($segment.pass -and $segment.event -eq 1 -and $segment.hr -eq 0) "Completion failed: $($fixture.name), threads $thread, $($segment.name)"
            Verify ($segment.monotonic -and $segment.timestamps) "Timestamp ordering failed: $($fixture.name), threads $thread, $($segment.name)"
            foreach ($frame in $segment.frame_data) {
                Verify ($frame.width -eq $fixture.width -and $frame.height -eq $fixture.height) "Dimensions changed: $($fixture.name), threads $thread, $($segment.name)"
                Verify ($frame.stop -gt $frame.start) "Non-positive frame time: $($fixture.name), threads $thread, $($segment.name)"
            }
            if ($segment.name -match 'seek|again') {
                $expected = @($whole.frame_data | Where-Object { $_.start -ge $segment.start -and $_.start -lt $segment.stop })
                $expectedSequence = @($expected | ForEach-Object sha256) -join ','
                Verify ($segment.frames -eq $expected.Count) "Seek frame coverage differs: $($fixture.name), threads $thread, $($segment.name), actual $($segment.frames), expected $($expected.Count), range [$($segment.start),$($segment.stop))"
                Verify ((Frame-Sequence $segment) -eq $expectedSequence) "Seek ordered pixels differ from complete whole-file time range: $($fixture.name), threads $thread, $($segment.name)"
                $seekCoverage += [pscustomobject]@{
                    segment=$segment.name
                    start=$segment.start
                    stop=$segment.stop
                    expected_frames=$expected.Count
                    actual_frames=$segment.frames
                    expected_first_absolute_start=if ($expected.Count) { $expected[0].start } else { $null }
                    expected_last_absolute_start=if ($expected.Count) { $expected[-1].start } else { $null }
                    passed=($segment.frames -eq $expected.Count -and (Frame-Sequence $segment) -eq $expectedSequence)
                }
            }
        }
        $forward = $report.segments | Where-Object name -EQ 'forward-seek'
        $forwardAgain = $report.segments | Where-Object name -EQ 'forward-again'
        Verify ((Frame-Sequence $forward) -eq (Frame-Sequence $forwardAgain)) "Repeated forward seek changes frames: $($fixture.name), threads $thread"
        Verify ((@($forward.frame_data | ForEach-Object start) -join ',') -eq (@($forwardAgain.frame_data | ForEach-Object start) -join ',')) "Repeated forward seek changes timestamps: $($fixture.name), threads $thread"
        $records += [pscustomobject]@{ fixture=$fixture.name; kind=$fixture.kind; bits=$fixture.bits; threads=$thread; reference_frames=$fixture.frames; source_sha256=$fixture.sha256; report=$report; seek_coverage=$seekCoverage; log=[IO.Path]::GetFileName($logPath) }
        Write-Output "$($fixture.name), threads ${thread}: whole=$($whole.frames), seeks=$($report.segments.Count - 2), md5=$($whole.md5)"
    }
}
foreach ($fixture in $manifest.fixtures) {
    $group = @($records | Where-Object fixture -EQ $fixture.name)
    if ($group.Count -gt 1) {
        $first = $group[0].report
        foreach ($other in $group[1..($group.Count-1)]) {
            for ($index=0; $index -lt [Math]::Min($first.segments.Count,$other.report.segments.Count); ++$index) {
                Verify ((Frame-Sequence $first.segments[$index]) -eq (Frame-Sequence $other.report.segments[$index])) "Thread setting changes decoded frames: $($fixture.name), $($first.segments[$index].name)"
                Verify ((@($first.segments[$index].frame_data | ForEach-Object start) -join ',') -eq (@($other.report.segments[$index].frame_data | ForEach-Object start) -join ',')) "Thread setting changes timestamps: $($fixture.name), $($first.segments[$index].name)"
            }
        }
    }
}
foreach ($binary in $candidateBinaries) {
    Verify ((Get-FileHash -LiteralPath (Join-Path $Package $binary.file) -Algorithm SHA256).Hash -eq $binary.sha256) "Candidate changed during validation: $($binary.file)"
}
Verify ((Get-FileHash -LiteralPath $capture -Algorithm SHA256).Hash -eq $harnessSha256) 'Harness changed during validation'
$summary = [pscustomobject]@{
    scope="$Platform accelerated headless DirectShow software decode; locally loaded filters, no registration; four official-source fixtures plus two synthetic stride fixtures with both YV12 and NV12 output"
    platform=$Platform
    pointer_bits=$expectedPointerBits
    harness=$capture
    package=$Package
    tested_utc=$testedUtc
    completed_utc=[DateTime]::UtcNow.ToString('o')
    candidate_binary_sha256=$candidateBinaries
    harness_sha256=$harnessSha256
    fixture_manifest_sha256=(Get-FileHash -LiteralPath (Join-Path $FixtureDirectory 'manifest.json') -Algorithm SHA256).Hash
    fixture_count=@($manifest.fixtures.file | Sort-Object -Unique).Count
    official_fixture_count=@($manifest.fixtures | Where-Object kind -NE 'synthetic-stride-regression' | ForEach-Object file | Sort-Object -Unique).Count
    synthetic_fixture_count=@($manifest.fixtures | Where-Object kind -EQ 'synthetic-stride-regression' | ForEach-Object file | Sort-Object -Unique).Count
    output_case_count=$manifest.fixtures.Count
    graph_runs=$records.Count
    segment_runs=(@($records | ForEach-Object { $_.report.segments }).Count)
    passed=($failures.Count -eq 0 -and $records.Count -eq $manifest.fixtures.Count * $Threads.Count)
    failures=@($failures)
    records=$records
}
$json = $summary | ConvertTo-Json -Depth 15
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'validation.json'), ($json -replace '\r?\n', "`r`n") + "`r`n", [Text.UTF8Encoding]::new($false))
if (-not $summary.passed) { throw "$($failures.Count) AVS validation failures; see validation.json" }
Write-Output "$($summary.graph_runs) graph runs / $($summary.segment_runs) decode-and-seek segments passed."
