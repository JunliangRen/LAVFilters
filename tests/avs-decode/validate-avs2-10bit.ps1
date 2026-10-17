param(
    [Parameter(Mandatory=$true)][string]$Package,
    [Parameter(Mandatory=$true)][string]$Fixture,
    [Parameter(Mandatory=$true)][string]$ReferenceReport,
    [Parameter(Mandatory=$true)][string]$HarnessDirectory,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [ValidateSet('x64','x86','Win32')][string]$Platform='x64',
    [ValidateRange(0,16)][int[]]$Threads=@(1,2),
    [ValidateRange(1,16)][int]$InstancesThreads=2,
    [string]$EightBitFixture,
    [ValidateRange(1000,3600000)][int]$SegmentTimeoutMs=600000,
    [ValidateRange(1000,7200000)][int]$InstancesTimeoutMs=1800000
)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if($Platform -eq 'Win32') {$Platform='x86'}
if(-not $EightBitFixture) {$EightBitFixture=Join-Path $root 'bin_build\avs-first\fixtures\avs2-bqsquare-ra.ts'}
$Package=(Resolve-Path -LiteralPath $Package).Path
$Fixture=(Resolve-Path -LiteralPath $Fixture).Path
$ReferenceReport=(Resolve-Path -LiteralPath $ReferenceReport).Path
$HarnessDirectory=(Resolve-Path -LiteralPath $HarnessDirectory).Path
$EightBitFixture=(Resolve-Path -LiteralPath $EightBitFixture).Path
$capture=Join-Path $HarnessDirectory "graph-regression-$Platform.exe"
$instances=Join-Path $HarnessDirectory "codec-instances-$Platform.exe"
foreach($path in @($capture,$instances)) {if(-not(Test-Path -LiteralPath $path)) {throw "Missing helper: $path"}}
if(Test-Path -LiteralPath $OutputDirectory) {
    if(@(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count) {throw 'Choose an empty OutputDirectory to preserve previous evidence'}
} else {New-Item -ItemType Directory -Path $OutputDirectory | Out-Null}
$OutputDirectory=(Resolve-Path -LiteralPath $OutputDirectory).Path
$summaryPath=Join-Path $OutputDirectory 'avs2-10bit-validation.json'
$reference=Get-Content -LiteralPath $ReferenceReport -Raw | ConvertFrom-Json
$inputHash=(Get-FileHash -LiteralPath $Fixture -Algorithm SHA256).Hash
$eightHash=(Get-FileHash -LiteralPath $EightBitFixture -Algorithm SHA256).Hash
if($inputHash -ne $reference.fixture_sha256) {throw '10-bit fixture differs from the independent reference input'}
if($reference.bits -ne 10 -or $reference.frames -le 0 -or @($reference.frame_sha256).Count -ne $reference.frames) {throw 'Reference must contain 10-bit frame count and ordered SHA256 values'}
$manifestPath=Join-Path (Split-Path $EightBitFixture -Parent) 'manifest.json'
$manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$manifestHash=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
$fixture8=@($manifest.fixtures | Where-Object {$_.sha256 -eq $eightHash}) | Select-Object -First 1
if(-not $fixture8) {throw '8-bit input not found in the unchanged core manifest'}
$reference8=Join-Path (Split-Path $manifestPath -Parent) $fixture8.reference_framehash
$hashes8=@(Get-Content -LiteralPath $reference8 | Where-Object {$_ -match '^0,'} | ForEach-Object {($_ -split ',')[-1].Trim()})
if($hashes8.Count -ne $fixture8.frames) {throw 'Incomplete existing 8-bit oracle'}
$expectedPointerBits=if($Platform -eq 'x64') {64} else {32}
$expectedMachine=if($Platform -eq 'x64') {0x8664} else {0x014c}
function Get-PeMachine([string]$Path) {
    $stream=[IO.File]::OpenRead($Path)
    $reader=[IO.BinaryReader]::new($stream)
    try {
        if($reader.ReadUInt16() -ne 0x5a4d) {throw "Missing MZ header: $Path"}
        $stream.Position=0x3c; $offset=$reader.ReadInt32(); $stream.Position=$offset
        if($reader.ReadUInt32() -ne 0x4550) {throw "Missing PE header: $Path"}
        return $reader.ReadUInt16()
    } finally {$reader.Dispose();$stream.Dispose()}
}
$testedUtc=[DateTime]::UtcNow.ToString('o')
$binaries=@(Get-ChildItem -LiteralPath $Package -Recurse -File | Where-Object Extension -In '.dll','.ax' | Sort-Object FullName | ForEach-Object {
    [pscustomobject]@{file=$_.FullName.Substring($Package.Length+1);sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash;pe_machine=(Get-PeMachine $_.FullName)}
})
$helperHashes=@{}
foreach($path in @($capture,$instances)) {$helperHashes[[IO.Path]::GetFileName($path)]=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
$failures=[Collections.Generic.List[string]]::new()
function Verify([bool]$Condition,[string]$Message) {if(-not $Condition) {$failures.Add($Message);Write-Warning $Message}}
function Sequence($Segment) {return (@($Segment.frame_data | ForEach-Object sha256) -join ',')}
function Run-Instances([string[]]$Arguments,[string]$Name) {
    $stdout=Join-Path $OutputDirectory "$Name.stdout.log"
    $stderr=Join-Path $OutputDirectory "$Name.stderr.log"
    $quoted=$Arguments | ForEach-Object {'"'+$_+'"'}
    $process=Start-Process -FilePath $instances -ArgumentList ($quoted -join ' ') -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -WindowStyle Hidden
    $completed=$process.WaitForExit($InstancesTimeoutMs)
    if(-not $completed) {$process.Kill();$process.WaitForExit()}
    $process.Refresh()
    Verify ($completed -and $process.ExitCode -eq 0) "$Name test failed or timed out, exit $($process.ExitCode)"
}
foreach($binary in $binaries) {Verify ($binary.pe_machine -eq $expectedMachine) "Candidate architecture differs: $($binary.file)"}
foreach($path in @($capture,$instances)) {Verify ((Get-PeMachine $path) -eq $expectedMachine) "Helper architecture differs: $path"}
$records=@()
foreach($thread in $Threads) {
    $json=Join-Path $OutputDirectory "avs2-10bit-threads-$thread.json"
    $log=Join-Path $OutputDirectory "avs2-10bit-threads-$thread.log"
    & $capture $Package $Fixture 10 $thread $json P010 $SegmentTimeoutMs 2>&1 | Out-File -LiteralPath $log -Encoding utf8
    $exit=$LASTEXITCODE
    Verify ($exit -eq 0) "10-bit graph failed, threads $thread, exit $exit"
    if(-not(Test-Path -LiteralPath $json)) {continue}
    try {$report=Get-Content -LiteralPath $json -Raw | ConvertFrom-Json} catch {$failures.Add("Invalid 10-bit graph report, threads $thread");continue}
    Verify ($report.pointer_bits -eq $expectedPointerBits) "Graph architecture differs from $Platform"
    Verify ($report.bits -eq 10 -and $report.output_format -eq 'P010' -and $report.decoder -eq 'avcodec') "Unexpected 10-bit graph decode path, threads $thread"
    Verify ($report.segments.Count -eq 5) "Missing seek/replay cases, threads $thread"
    $whole=$report.segments | Where-Object name -EQ 'whole-file'
    $replay=$report.segments | Where-Object name -EQ 'whole-replay'
    Verify ($whole.frames -eq $reference.frames) "Whole frame count differs from independent reference, threads $thread"
    Verify ($whole.md5 -eq $reference.md5 -and (Sequence $whole) -eq ($reference.frame_sha256 -join ',')) "P010 canonical pixels differ from independent reference, threads $thread"
    Verify ($whole.bytes -eq ([uint64]$reference.width*$reference.height*3*$reference.frames)) "Unexpected canonical 10-bit byte count, threads $thread"
    Verify ($whole.precision_samples -gt 0) "10-bit low precision samples absent, threads $thread"
    Verify ((Sequence $replay) -eq (Sequence $whole) -and $replay.md5 -eq $whole.md5) "Replay changes decoded pixels, threads $thread"
    $coverage=@()
    foreach($segment in $report.segments) {
        Verify ($segment.pass -and $segment.event -eq 1 -and $segment.hr -eq 0) "Completion failed, threads $thread, $($segment.name)"
        Verify ($segment.monotonic -and $segment.timestamps) "Timestamp ordering failed, threads $thread, $($segment.name)"
        foreach($frame in $segment.frame_data) {
            Verify ($frame.width -eq $reference.width -and $frame.height -eq $reference.height) "Dimensions changed, threads $thread, $($segment.name)"
            Verify ($frame.stop -gt $frame.start) "Non-positive frame time, threads $thread, $($segment.name)"
            if($reference.frame_rate) {
                Verify ([Math]::Abs(($frame.stop-$frame.start)-(10000000.0/$reference.frame_rate)) -le 1) "Frame duration differs from the declared rate, threads $thread, $($segment.name)"
            }
        }
        if($segment.name -match 'seek|again') {
            $expected=@($whole.frame_data | Where-Object {$_.start -ge $segment.start -and $_.start -lt $segment.stop})
            $match=$segment.frames -eq $expected.Count -and (Sequence $segment) -eq (@($expected | ForEach-Object sha256) -join ',')
            Verify $match "Complete seek coverage differs, threads $thread, $($segment.name): $($segment.frames)/$($expected.Count)"
            $coverage += [pscustomobject]@{name=$segment.name;expected_frames=$expected.Count;actual_frames=$segment.frames;passed=$match}
        }
    }
    $forward=$report.segments | Where-Object name -EQ 'forward-seek'
    $again=$report.segments | Where-Object name -EQ 'forward-again'
    Verify ((Sequence $forward) -eq (Sequence $again) -and (@($forward.frame_data | ForEach-Object start) -join ',') -eq (@($again.frame_data | ForEach-Object start) -join ',')) "Repeated seek changes pixels/times, threads $thread"
    $records += [pscustomobject]@{threads=$thread;report_file=[IO.Path]::GetFileName($json);report_sha256=(Get-FileHash -LiteralPath $json -Algorithm SHA256).Hash;seek_coverage=$coverage;report=$report}
    Write-Output "$Platform AVS2 10-bit threads ${thread}: $($whole.frames) P010 frames, $($coverage.Count) complete seek ranges"
}
$instancesJson=Join-Path $OutputDirectory 'codec-instances.json'
Run-Instances -Arguments @($Package,$EightBitFixture,$Fixture,$instancesJson,"$InstancesThreads") -Name 'codec-instances'
$instanceReport=$null
if(Test-Path -LiteralPath $instancesJson) {
    try {$instanceReport=Get-Content -LiteralPath $instancesJson -Raw | ConvertFrom-Json} catch {$failures.Add('Invalid same-process instance report')}
}
if($instanceReport) {
    Verify ($instanceReport.pointer_bits -eq $expectedPointerBits -and $instanceReport.passed -and $instanceReport.run_count -eq 16 -and $instanceReport.runs.Count -eq 16) 'Same-process instance test did not complete all 16 runs'
    foreach($run in $instanceReport.runs) {Verify ([bool]$run.pass) "Instance run failed: $($run.name)"}
    $base10=$instanceReport.runs | Where-Object name -EQ 'baseline-10'
    Verify ($base10.frames -eq $reference.frames -and $base10.md5 -eq $reference.md5 -and (Sequence $base10) -eq ($reference.frame_sha256 -join ',')) 'Direct API 10-bit baseline differs from independent reference'
    $base8=$instanceReport.runs | Where-Object name -EQ 'baseline-8'
    Verify ($base8.frames -eq $fixture8.frames -and $base8.md5 -eq $fixture8.reference_md5 -and (Sequence $base8) -eq ($hashes8 -join ',')) 'Direct API 8-bit baseline differs from the existing published oracle'
}
$coldRecords=@()
foreach($bits in @(8,10)) {
    $coldJson=Join-Path $OutputDirectory "codec-cold-$bits.json"
    $coldFixture=if($bits -eq 10) {$Fixture} else {$EightBitFixture}
    Run-Instances -Arguments @("--cold-$bits",$Package,$coldFixture,$coldJson,"$InstancesThreads") -Name "codec-cold-$bits"
    if(-not(Test-Path -LiteralPath $coldJson)) {Verify $false "Missing cold $bits-bit report";continue}
    try {$cold=Get-Content -LiteralPath $coldJson -Raw | ConvertFrom-Json} catch {$failures.Add("Invalid cold $bits-bit report");continue}
    Verify ($cold.pointer_bits -eq $expectedPointerBits -and $cold.bits -eq $bits -and $cold.probe_warmed_decoder -eq $false -and $cold.passed -and $cold.run_count -eq 3 -and $cold.runs.Count -eq 3) "Cold $bits-bit test did not complete all three runs"
    $expectedFrames=if($bits -eq 10) {$reference.frames} else {$fixture8.frames}
    $expectedMd5=if($bits -eq 10) {$reference.md5} else {$fixture8.reference_md5}
    $expectedHashes=if($bits -eq 10) {$reference.frame_sha256} else {$hashes8}
    foreach($run in $cold.runs) {
        Verify ([bool]$run.pass) "Cold $bits-bit run failed: $($run.name)"
        Verify ($run.frames -eq $expectedFrames -and $run.md5 -eq $expectedMd5 -and (Sequence $run) -eq ($expectedHashes -join ',')) "Cold $bits-bit pixels differ from independent oracle: $($run.name)"
    }
    $coldRecords += [pscustomobject]@{bits=$bits;report_file=[IO.Path]::GetFileName($coldJson);report_sha256=(Get-FileHash -LiteralPath $coldJson -Algorithm SHA256).Hash;report=$cold}
}
foreach($binary in $binaries) {Verify ((Get-FileHash -LiteralPath (Join-Path $Package $binary.file) -Algorithm SHA256).Hash -eq $binary.sha256) "Candidate changed during validation: $($binary.file)"}
foreach($path in @($capture,$instances)) {Verify ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $helperHashes[[IO.Path]::GetFileName($path)]) "Helper changed during validation: $path"}
Verify ((Get-FileHash -LiteralPath $Fixture -Algorithm SHA256).Hash -eq $inputHash) '10-bit source prefix changed during validation'
Verify ((Get-FileHash -LiteralPath $EightBitFixture -Algorithm SHA256).Hash -eq $eightHash) '8-bit control changed during validation'
Verify ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -eq $manifestHash) 'Existing fixture manifest changed during validation'
$summary=[pscustomobject]@{
    passed=($failures.Count -eq 0 -and $records.Count -eq $Threads.Count -and $null -ne $instanceReport -and $coldRecords.Count -eq 2)
    platform=$Platform
    pointer_bits=$expectedPointerBits
    package=$Package
    tested_utc=$testedUtc
    completed_utc=[DateTime]::UtcNow.ToString('o')
    fixture=$Fixture
    fixture_bytes=(Get-Item -LiteralPath $Fixture).Length
    fixture_sha256=$inputHash
    eight_bit_control=$EightBitFixture
    eight_bit_control_sha256=$eightHash
    existing_fixture_manifest_sha256=$manifestHash
    reference_report=$ReferenceReport
    reference_report_sha256=(Get-FileHash -LiteralPath $ReferenceReport -Algorithm SHA256).Hash
    independent_reference=$reference.reference
    reference_limits=$reference.limits
    candidate_binary_sha256=$binaries
    helper_sha256=$helperHashes
    graph_runs=$records.Count
    segment_runs=@($records | ForEach-Object {$_.report.segments}).Count
    instance_report_file=[IO.Path]::GetFileName($instancesJson)
    instance_report_sha256=if(Test-Path -LiteralPath $instancesJson) {(Get-FileHash -LiteralPath $instancesJson -Algorithm SHA256).Hash} else {$null}
    instance_report=$instanceReport
    cold_process_runs=$coldRecords.Count
    cold_instance_runs=@($coldRecords | ForEach-Object {$_.report.runs}).Count
    cold_records=$coldRecords
    failures=@($failures)
    records=$records
    limits='Only the supplied unchanged short broadcast prefix, not the full recording. Software decode with headless pixel capture verifies P010 precision, ordered pixels, timestamps, seek/replay, and EOS. Same-process API tests cover interleaved/concurrent 8/10-bit instances, flush discard, and bit-depth changes with/without flush. These are not renderer, audio/video synchronization, default-thread memory, sustained playback, or real-time throughput measurements. The separate existing core suite remains required for AVS1/8-bit AVS2/AVS3 regressions.'
}
$text=$summary | ConvertTo-Json -Depth 18
[IO.File]::WriteAllText($summaryPath,($text -replace '\r?\n',"`r`n")+"`r`n",[Text.UTF8Encoding]::new($false))
if(-not $summary.passed) {throw "$($failures.Count) AVS2 10-bit validation failures; see $summaryPath"}
Write-Output "$($summary.graph_runs) graph runs / $($summary.segment_runs) seek-and-replay segments plus 16 mixed-depth API and 6 cold-start API runs passed."
